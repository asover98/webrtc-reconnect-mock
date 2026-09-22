# ADR Draft: iOS WebRTC + WebSocket Reconnect

| Field | Value |
| --- | --- |
| Status | **Draft** (research / decision record, not yet Accepted) |
| Date | 2026-09-10 (Europe/Moscow) |
| Scope | iOS client mock: pure Swift + WebRTC (`LiveKitWebRTC` binary), multiparty SFU-style room |
| Problems | (1) Seamless reconnect after loss / LTE↔WiFi (2) Do not lose A/V streams on reconnect (3) Under bad network, at least keep audio |
| Audience | Engineers implementing `WebRTCReconnectMock` |

> **Citation policy:** Only sources consulted for this draft are listed in §References. Claims marked **[uncertain]** are inferences or industry practice not pinned to a single normative text. Do not treat secondary blogs as normative where an RFC/W3C/SDK doc exists.

---

## 1. Context

### 1.1 Product / mock constraints

- **Client:** iOS, Swift, using the **LiveKitWebRTC** binary (Google libwebrtc packaging used by LiveKit’s Swift ecosystem). Not WKWebView; native `RTCPeerConnection` APIs.
- **Topology:** Multiparty **mock SFU** (one PeerConnection toward the media server per client is the design target; exact dual-PC publisher/subscriber split is an open question — see §8).
- **Signaling:** App-owned **WebSocket** to a mock signaling server (not the full LiveKit cloud protocol, but we deliberately **compare** LiveKit/Twilio reconnect models).
- **User pain (acceptance criteria):**
  1. After brief outage or LTE↔WiFi handoff, call recovers without “leave room / rejoin” UX when possible.
  2. Audio/video **tracks and transceiver identity** survive the common reconnect path (no blank tiles / silent remotes solely because of reconnect bookkeeping).
  3. When bandwidth collapses, **audio remains intelligible** even if video is degraded or paused.

### 1.2 Layering model (signaling ≠ ICE ≠ media)

| Layer | Failure mode | Recovery primitive |
| --- | --- | --- |
| Signaling WebSocket | Socket closed, TLS reset, NAT timeout | **WS resume** (session id + cursor) or full re-auth join |
| ICE / DTLS transport | Path dead after interface change, consent failure | **ICE restart** (new `ice-ufrag`/`ice-pwd`) or **PeerConnection recycle** |
| RTP media / SFU state | Track SIDs, mids, subscriptions desynced | SyncState / republish / resubscribe |
| Congestion | Not “disconnected”, but starving | Prefer-audio policy + BWE |

Industry SDKs separate these deliberately:

- **LiveKit:** On network change, reconnect signaling WS and initiate **ICE restart**; if that fails, **full reconnection** (republish/resubscribe). See LiveKit “Connecting to LiveKit” docs.
- **Twilio Video:** Emits room `reconnecting` / `reconnected` for signaling and/or media; distinguishes error codes for signaling vs media reconnect. AccessToken TTL must outlive the session or reconnect fails.

### 1.3 Normative anchors (short)

- **ICE restart exists** so a session can gather a new checklist without tearing down the call: RFC 8445 §2.4 / §9 (ICE Restarts); SDP procedures in RFC 8839 §4.4.1.1.1 (both `ice-ufrag` and `ice-pwd` MUST change).
- **W3C WebRTC** exposes `RTCPeerConnection.restartIce()` and `createOffer({ iceRestart: true })`; recommends restart when `iceConnectionState` → `"failed"`, and optionally after `"disconnected"` plus stats heuristics (W3C WebRTC REC, Offer/Answer Options; MDN `restartIce`).
- **MDN:** After `restartIce()`, “Existing media transmissions continue uninterrupted during this process” (API note; gap length is implementation/network dependent).
- **Consent freshness:** Community guidance from discuss-webrtc (Google) notes that once consent is lost (order of ~30s without STUN consent), an ICE restart is required — you cannot simply “wait longer” past that bound. **[uncertain on exact timer wiring in LiveKitWebRTC iOS binary — verify against linked libwebrtc version.]**

---

## 2. Decision drivers

| ID | Driver | Preference |
| --- | --- | --- |
| D1 | Minimize media gap on LTE↔WiFi | Prefer in-place ICE restart over PC recreate |
| D2 | Preserve local `RTCMediaStreamTrack` / encoder state | Avoid removeTrack/addTrack during recovery |
| D3 | Preserve remote tile identity in multiparty UI | Stable keys: participant identity + track SID / mid |
| D4 | Survives signaling-only blips | WS resume with session id + cursor |
| D5 | Works when SFU state diverged | Escalate to full PC recycle + republish |
| D6 | Bad network: intelligible audio | Prefer-audio / degrade video first |
| D7 | Debuggability in mock | Explicit reconnect modes, metrics, test hooks |
| D8 | Do not invent LiveKit protocol compatibility | Mock may **learn from** LiveKit/Twilio; not claim wire-compat |

**Non-goals for this mock:** E2EE key rotation, SFU cluster migration, Exact LiveKit protobuf parity, cellular QoS / DSCP tuning on carrier networks.

---

## 3. Problem 1 — Seamless reconnect after connection loss / LTE↔WiFi

### 3.1 Options compared

| Option | Mechanism | Pros | Cons | Verdict |
| --- | --- | --- | --- | --- |
| **A. Do nothing / wait for ICE** | Hope consent checks revive same pair | Zero code | Fails on interface change (new host candidates needed); consent loss forces restart | **Reject** for mobile handoff |
| **B. ICE restart on existing PC** | New ufrag/pwd; gather; trickle; keep old nominated pair until new nomination (RFC 8445 spirit; W3C `restartIce`) | Keeps DTLS/SRTP/track state; industry default (LiveKit “resume”) | Needs working signaling; SFU must accept restart; may still gap | **Recommend (primary)** |
| **C. Full PeerConnection recycle** | `close()` PC, new PC, renegotiate, republish | Always possible; clears stuck DTLS | Multi-second gap; UI churn; LiveKit “full reconnect” semantics | **Escalate / fallback** |
| **D. Tear down room / rejoin** | Leave + join as new participant | Simple server | Worst UX; new participant SID; breaks “seamless” | **Reject** as primary |
| **E. App-level “shadow” second PC** | Parallel PC, switch when ready | Can hide gap | 2× media/CPU; complex glare; overkill for mock | **Reject** for mock |
| **F. WS-only reconnect, ignore ICE** | Reopen socket, no media repair | Fixes chat/signaling | Leaves media dead after path change | **Reject** alone |

### 3.2 Recommendation (Problem 1)

**Ladder (aligns with LiveKit + W3C):**

1. **Detect** path / connectivity change early:
   - iOS: `NWPathMonitor` (satisfied / expensive / interface type) **[uncertain: LiveKitWebRTC may also surface network change via `RTCNetworkMonitor` — confirm in binary version]**.
   - WebRTC: `iceConnectionState` / `connectionState` → `disconnected` | `failed`.
2. **Debounce** ~300ms after path change so the OS finishes addressing (industry practice; **[uncertain exact debounce]**).
3. Ensure **signaling is up** (WS resume — §5) before or in parallel with media repair.
4. Refresh **TURN credentials** via `setConfiguration` if TTL may have expired, then **`restartIce()`** (or `createOffer(iceRestart: true)` if driving offers manually). W3C + MDN: restart on `failed`; on `disconnected`, optionally wait and use `getStats` byte counters.
5. Cap restart attempts (e.g. **3**), then escalate to **full PC recycle**.
6. Do **not** treat successful zero-gap restart as requiring `connectionState` to leave `connected` — completion is better observed via new selected candidate pair / gathering complete (**[uncertain on exact LiveKitWebRTC stats field names]**).

### 3.3 When to escalate to full PeerConnection recycle

Escalate when **any** of:

| Trigger | Rationale |
| --- | --- |
| ICE restart budget exhausted | Stuck checklist / no usable candidates |
| DTLS / SRTP failure after restart | Transport crypto state corrupted |
| Signaling session irrevocably lost (auth expired) | Cannot exchange restart SDP |
| SFU reports publication / subscription mismatch on resume | LiveKit server PR #1823 pattern: resume with divergent track set → full reconnect |
| Local PC `closed` or non-recoverable `failed` after restart | Stack requires fresh agent |
| Airplane mode long enough that consent + TURN allocation both dead **and** restart fails | Clean slate cheaper than fighting |

---

## 4. Problem 2 — Do not lose audio/video streams on reconnect

### 4.1 What “lose streams” means

| Failure | Symptom | Root |
| --- | --- | --- |
| Transport gap only | Brief freeze/silence, then same tracks | Expected during ICE restart |
| Track object churn | UI recreates renderers; flicker; “ghost” tiles | Handlers not idempotent on republish |
| Mid / SSRC / SID remap | Wrong tile, silent track, decoder waiting keyframe | Full reconnect without stable identity keys |
| Premature unsubscribe | Audio gone after “successful” resume | Race: SyncState before remote track attached (LiveKit Swift issue #859 class of bugs) |
| Local republish without `replaceTrack` reuse | Camera restart, permission flash | Unnecessary `addTrack` instead of keeping sender |

### 4.2 Options compared

| Option | Mechanism | Pros | Cons | Verdict |
| --- | --- | --- | --- | --- |
| **A. ICE restart only; keep senders/receivers** | Same m-lines, mids, DTLS fingerprint continuity | Best continuity; MDN: media continues during restart | Requires SFU cooperation; doesn’t fix SID mismatch | **Recommend (fast path)** |
| **B. Full reconnect + republish/resubscribe** | New session; new track SIDs possible | Reliable after divergence | Event storm; needs idempotent UI | **Recommend (slow path)** |
| **C. `replaceTrack` during reconnect** | Swap tracks on existing senders | Useful for device switch | **Reject** as default reconnect tool — can drop encoder path if bundled into restart |
| **D. Always recreate PC on any blip** | Simpler mental model | Guarantees “works eventually” | Violates seamless + stream continuity goals | **Reject** as primary |
| **E. Stable identity keys in app** | UI keyed by `participant.identity` + `trackSid` (or mid), not PC object identity | Survives full reconnect | Must handle SID change on rejoin (Flutter LiveKit PR #937 lesson) | **Recommend (always)** |
| **F. App SyncState (session SDP + subscription cursor)** | Mirror LiveKit `SyncState` idea | Prevents silent desync | Must avoid racing track attach | **Recommend for mock SFU** |

### 4.3 Recommendation (Problem 2)

1. **Fast path:** ICE restart **without** touching transceiver set; keep local `RTCAudioTrack`/`RTCVideoTrack` instances; do not stop camera/mic.
2. **Signaling resume:** Carry **session id**, last **signaling cursor** (seq), and optional **SDP snapshot** so the SFU can continue the same media session (LiveKit: reconnect + `SyncState` with answer/offer/subscription/publish_tracks).
3. **SFU mid/track continuity notes (for mock design):**
   - **Resume / ICE restart:** Prefer **stable mids** and **stable track SIDs**; SFU keeps forwarding the same publications. Client should **not** emit “track unpublished/published” for the same logical track.
   - **Full reconnect:** Treat like leave+join: new participant SID possible; **identity** stable; **new track SIDs** possible. UI and analytics handlers **must be idempotent**. LiveKit documents the full-reconnect event sequence (`ParticipantDisconnected` → `Reconnecting` → `Reconnected` → `ParticipantConnected` → `LocalTrackPublished`).
   - **Mismatch:** If client believes a track is published but server does not (or vice versa), **do not** limp on resume — escalate to full recycle (LiveKit server behavior on publication mismatch).
   - **Keyframe:** After transport recovery, if `bytesReceived` climbs but frames do not decode, request PLI/FIR rather than another ICE restart (**[uncertain: exact API on LiveKitWebRTC]**).
4. **Reject** coupling track surgery (`removeTrack`, transceiver `stop`, narrowing `iceTransportPolicy` to `relay` mid-call without plan) into the restart offer — those change session semantics and can drop the path still carrying RTP.

### 4.4 When to escalate to full PeerConnection recycle

Same as §3.3, plus:

- Remote track map empty after “successful” resume while peers are still in room.
- Duplicate mids / broken BUNDLE after answer.
- DataChannel unreliable seq gap unrecoverable **and** app requires ordered control plane on SCTP (**[uncertain if mock uses SCTP DC]**).

---

## 5. Problem 3 — Under bad network, at least keep audio

This is **not** primarily a reconnect problem; it is **congestion & priority** while still “connected”.

### 5.1 Options compared

| Option | Mechanism | Pros | Cons | Verdict |
| --- | --- | --- | --- | --- |
| **A. Rely on libwebrtc BitrateAllocator defaults** | Audio gets protected min; video absorbs cut | Works out of the box in many builds | Opaque; may still pause audio if `enforce_min_bitrate` false under extreme BWE | **Baseline accept** |
| **B. Explicit prefer-audio policy** | On poor NQE: pause/disable video sender, keep audio; optionally lower Opus maxaveragebitrate | Clear product behavior; testable | Needs thresholds; video UX impact | **Recommend** |
| **C. Simulcast / SVC layer drop only** | SFU forwards lowest layer | Good when SFU supports it | Mock SFU may lack layers; still competes with audio on uplink | **Recommend if mock has simulcast** |
| **D. Opus DTX + in-band FEC** | Silence savings; loss resilience | Helps multiparty uplink | DTX often needs fmtp/`usedtx`; FEC tradeoffs | **Recommend investigate** |
| **E. W3C Priority Control (`priority` / `networkPriority`)** | Encoding priority + DSCP hints (W3C webrtc-priority; RFC 8835/8837) | Standards-based | Limited carrier DSCP effect on cellular; API availability on LiveKitWebRTC **[uncertain]** | **Optional** |
| **F. Drop audio to save video** | — | — | Violates problem statement | **Reject** |
| **G. Hardcode tiny video always** | Always 90p | Predictable | Wastes good networks; poor product | **Reject** as sole strategy |

### 5.2 Recommendation (Problem 3)

**Prefer-audio policy for the mock:**

1. Continuously sample: outbound/inbound loss, RTT, `availableOutgoingBitrate` (via `getStats`), and/or a simple app Network Quality Estimate.
2. **Soft degrade:** Reduce video `maxBitrate` / resolution / framerate first.
3. **Hard prefer-audio:** Below threshold T1, set video encodings `active = false` (or unmute→disable video track) while **keeping audio sender active**.
4. Configure audio with a **protected floor** (target ~16–40 kbps Opus for speech; do not starve below ~12 kbps without listening tests — secondary guidance).
5. Enable **Opus FEC** under loss when available; consider DTX for multiparty silence.
6. Do **not** trigger ICE restart solely for congestion — restart is for path failure, not bitrate.

Twilio’s Bandwidth Profile / Track Priority APIs are a productized form of the same idea (protect audio and high-priority video under congestion); the mock can implement a minimal subset without Twilio.

---

## 6. Recommended stack for `WebRTCReconnectMock`

```
┌──────────────────────────────────────────────────────────┐
│  App session                                             │
│   • roomId, participantIdentity, auth token TTL ≥ call   │
│   • NetworkQuality monitor → PreferAudioPolicy           │
└───────────────┬───────────────────────────┬──────────────┘
                │                           │
                ▼                           ▼
┌───────────────────────────┐   ┌──────────────────────────┐
│ SignalingClient (WS)      │   │ PeerConnectionController │
│  • sessionId              │   │  • LiveKitWebRTC PC      │
│  • resume cursor (seq)    │   │  • ICE restart first     │
│  • exponential backoff    │   │  • escalate → recycle    │
│  • reconnect ≠ rejoin     │   │  • keep tracks/senders   │
└─────────────┬─────────────┘   └────────────┬─────────────┘
              │  resume / sync               │ restart SDP
              ▼                              ▼
┌───────────────────────────┐   ┌──────────────────────────┐
│ Mock SFU / Signaling      │   │ Media (RTP)              │
│  • accept WS resume       │   │  • mid/SID continuity    │
│  • ICE restart O/A        │   │  • keyframe on recover   │
│  • SyncState validation   │   │  • prefer-audio allocate │
└───────────────────────────┘   └──────────────────────────┘
```

### 6.1 WS resume (session id + cursor)

**Accepted approach for mock:**

| Field | Purpose |
| --- | --- |
| `sessionId` | Server-side signaling session; distinguishes resume from new join |
| `participantSid` (optional) | If mock assigns SIDs; detect rejoin vs resume |
| `cursor` / `lastSeq` | Last processed server→client message; replay or gap-fill |
| `reconnect=true` | Explicit mode flag (LiveKit Join pattern) |
| Token | Must still be valid (Twilio lesson: expired AccessToken → reconnect fail) |

**Reject:** Silent reconnect that always creates a **new** session id (forces full media reset).  
**Reject:** Infinite reconnect without backoff (Twilio `SignalingServerBusyError` class of failure).

### 6.2 ICE restart first

- On path change or `iceConnectionState == .failed`: refresh ICE servers if needed → `restartIce()` → create/send offer with new credentials.
- On `disconnected`: grace 2–3s + stats; if bytes stall and path changed, restart early.
- Answerer: when remote offer has new ufrag/pwd, answer with new credentials (RFC 8839); do not blindly double-`restartIce` unless generating a new offer.

### 6.3 SFU mid/track continuity

| Mode | mid | track SID | local tracks | remote UI |
| --- | --- | --- | --- | --- |
| WS resume + ICE restart | **stable** | **stable** | keep | no republish events |
| Full PC recycle | may rematerialize | **may change** | republish | idempotent handlers; key by identity |

### 6.4 Prefer-audio policy

Ship as an explicit `PreferAudioPolicy` with injectable thresholds and a debug HUD (audio-only badge). Default: degrade video before audio; never the reverse.

---

## 7. Test matrix for the mock

| # | Scenario | How to induce | Expect (fast path) | Expect (escalate) | Metrics to log |
| --- | --- | --- | --- | --- | --- |
| T1 | **Path change WiFi→LTE** | Control Center / physical SIM; or Network Link Conditioner + disable WiFi | WS resume + ICE restart; A/V continue; ≤ ~1–2s media hitch **[uncertain bound]** | Full recycle if restart fails | path events, ice states, restart count, gap ms |
| T2 | **Path change LTE→WiFi** | Same | Same as T1 | Same | same |
| T3 | **Airplane toggle short** | Airplane 3–5s then off | Resume + restart; sessionId same | If > consent window, may need recycle | offline duration, consent |
| T4 | **Airplane toggle long** | Airplane 45–60s | Likely recycle or re-auth | New PC; possibly new track SIDs | token validity |
| T5 | **Kill WS only** | Server drop / `URLSession` cancel without touching UDP | WS resume; **no** ICE restart if media still flowing | If app wrongly recycles PC → fail test | media bytes during WS down |
| T6 | **Kill media path only** | Block UDP / firewall; keep WS | ICE restart over WS; media returns | Recycle | iceRestart offers |
| T7 | **Packet loss 5–15%** | Network Link Conditioner | Prefer-audio may soft-degrade; call stays up | N/A | loss%, audio conceal, video fps |
| T8 | **Bandwidth cliff** | Cap ~100 kbps | Video pauses/low; **audio remains** | Fail if audio drops first | audio bitrate, video active |
| T9 | **Glare during restart** | Both sides offer | Perfect-negotiation or SFU-as-offer-authority | Stuck signaling | signalingState |
| T10 | **Expired TURN during restart** | Short-lived creds | Detect; `setConfiguration` refresh; retry | Recycle | allocate errors |
| T11 | **Full reconnect UI idempotency** | Force recycle | Single tile per identity; no duplicate renderers | — | publish event counts |
| T12 | **SyncState race** | Delay remote track attach; resume | Must **not** unsubscribe live tracks | — | subscription cmds |

**Automation notes:** Prefer injectable `Connectivity` and `PeerConnection` fakes for CI; use manual device matrix for T1–T4. Record `RTCStatisticsReport` snapshots around transitions.

---

## 8. Open questions

1. **Single vs dual PeerConnection** toward mock SFU (LiveKit often uses publisher + subscriber PCs). Affects which SDP is stored in SyncState.
2. **Exact LiveKitWebRTC ObjC API** for `restartIce` / offer options / network monitor on the pinned binary version — verify headers before implementation.
3. **Consent freshness timer** and whether airplane toggles of duration D always require restart in this binary.
4. Should the **mock SFU** be offerer-locked (server authoritative) to avoid glare, or implement perfect negotiation on clients?
5. **Track SID minting:** stable across ICE restart only, or also across full recycle within the same `sessionId`?
6. **DataChannels:** required for mock control plane? If yes, resume must include DC seq (LiveKit `datachannel_receive_states`).
7. **Priority Control API** availability in LiveKitWebRTC iOS — if absent, rely on app-level video pause.
8. **Token refresh** during long calls: refresh before reconnect attempt (Twilio 24h guidance is cloud-specific; mock should define its own TTL).
9. **Video keyframe** request API path after seamless ICE restart when decoder stalls.
10. Whether to surface separate UI for **signal reconnecting** vs **media reconnecting** (LiveKit `SignalReconnecting` vs `Reconnecting` lesson).

---

## 9. Decision summary (draft)

| Decision | Choice | Rejected |
| --- | --- | --- |
| Primary media recovery | **ICE restart on existing PC** | Immediate PC recreate; room rejoin |
| Primary signaling recovery | **WS resume (sessionId + cursor)** | New session on every socket blip |
| Stream continuity | Keep senders/tracks; stable identity keys; SyncState | Track surgery during restart |
| Escalation | Full PC recycle + republish after budget/mismatch | Infinite restart loops |
| Bad network | **Prefer-audio** degrade/pause video | Drop audio to protect video |
| Inspiration | LiveKit resume/full ladder; Twilio reconnect states; W3C/IETF ICE | Claiming wire-level LiveKit compatibility |

---

## References

### Normative / primary

1. IETF **RFC 8445** — *Interactive Connectivity Establishment (ICE)*, July 2018. ICE Restart overview §2.4; ICE Restarts §9. https://www.rfc-editor.org/rfc/rfc8445.html  
2. IETF **RFC 8839** — *SDP Offer/Answer Procedures for ICE*. ICE Restart §4.4.1.1.1 / answerer §4.4.2.1 (both `ice-ufrag` and `ice-pwd` MUST change). https://www.rfc-editor.org/rfc/rfc8839.html  
3. IETF **RFC 9429** — *JavaScript Session Establishment Protocol (JSEP)*. ICE gathering / `needs-ice-restart` / `setConfiguration` effects. https://www.rfc-editor.org/rfc/rfc9429.html  
4. W3C **WebRTC 1.0** Recommendation (13 March 2025) — `RTCOfferOptions.iceRestart`, `restartIce()`, guidance on `failed` / `disconnected`. https://www.w3.org/TR/webrtc/ and editor’s draft https://w3c.github.io/webrtc-pc/  
5. MDN — `RTCPeerConnection.restartIce()` (notes media continues during restart; references RFC 5245 §9.1.1.1 historically). https://developer.mozilla.org/en-US/docs/Web/API/RTCPeerConnection/restartIce  
6. MDN — `RTCPeerConnection.setConfiguration()` (refresh ICE servers then restart). https://developer.mozilla.org/en-US/docs/Web/API/RTCPeerConnection/setConfiguration  
7. W3C **WebRTC Priority Control API**. https://www.w3.org/TR/webrtc-priority/  

### Product / SDK documentation (comparative)

8. LiveKit Docs — *Connecting to LiveKit* — Network changes and reconnection (WS reconnect + ICE restart; full reconnect sequence). https://docs.livekit.io/intro/basics/connect/  
9. LiveKit protocol — `SyncState`, `ReconnectResponse`, join `reconnect` fields in `livekit_rtc.proto`. https://github.com/livekit/protocol/blob/main/protobufs/livekit_rtc.proto  
10. Twilio Docs — *Reconnection States and Events* (signaling vs media reconnect; AccessToken TTL). https://www.twilio.com/docs/video/reconnection-states-and-events  

### Implementation / incident evidence (non-normative)

11. LiveKit Swift — reconnection modes discussion / mintlify guide (quick vs full). https://livekit-client-sdk-swift.mintlify.app/guides/reconnection  
12. LiveKit community — WiFi→cellular handling & `SignalReconnecting` vs `Reconnecting`. https://community.livekit.io/t/wifi-cellular-mid-call-what-livekit-already-handles-and-the-two-things-that-still-bite/1731  
13. LiveKit client-sdk-swift issue #859 — resume SyncState race unsubscribing tracks. https://github.com/livekit/client-sdk-swift/issues/859  
14. LiveKit server PR #1823 — full reconnect on publication mismatch on resume. https://github.com/livekit/livekit/pull/1823  
15. discuss-webrtc — ICE restart on network change / consent freshness (~30s). https://groups.google.com/g/discuss-webrtc/c/jUFmTalowfU  
16. libwebrtc `call/bitrate_allocator.h` — `min_bitrate_bps`, `enforce_min_bitrate` (audio protection knobs). https://webrtc.googlesource.com/src.git/+/refs/heads/main/call/bitrate_allocator.h  

### Secondary explainers (use cautiously)

17. BlogGeek.me — ICE Restart glossary (restart vs new PC tradeoffs). https://bloggeek.me/webrtcglossary/ice-restart/  
18. RTMA — Connection Recovery & ICE Restart (operational heuristics; not IETF). https://www.real-time-media-architecture.com/webrtc-protocol-stack-signaling-servers/connection-recovery-ice-restart/  

---

## Revision history

| Rev | Date (MSK) | Notes |
| --- | --- | --- |
| 0.1 | 2026-09-10 19:40 | Initial ADR-quality research draft for WebRTCReconnectMock |
