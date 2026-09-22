# WebRTCReconnectMock

Research / spike sample: three practical WebRTC problems on iOS, plus a small experiment on whether **deterministic agents** and an optional **LLM tool-caller** help media policy under bad networks.

Stack: SwiftUI + **[LiveKitWebRTC](https://github.com/livekit/webrtc-xcframework)** (LK-prefixed APIs). Default signaling is in-process loopback (`mock://local`). Optional LiveKit Cloud A/V is a separate scheme — see [docs/LIVEKIT-ROOM-TEST.md](docs/LIVEKIT-ROOM-TEST.md).

## Research questions

1. **Seamless reconnect** after brief loss or LTE↔Wi‑Fi — without forcing “leave room / rejoin” when a lighter recovery is enough.
2. **A/V continuity** across that recovery — keep track / transceiver identity so tiles don’t go blank solely because of bookkeeping.
3. **Prefer-audio under congestion** — when bandwidth collapses, keep audio intelligible even if video is degraded or paused.

Extra spike (not required to study the ladder):

- **UI coalescing** — many noisy conference UI events → one shared room model → ~1 Hz UI snapshot.
- **Agents + tools** — policy decides knobs; tools apply them to `WebRTCClient`. Same tool shape is exercised offline in `llm-demo/` (optional live LLM).

Design notes: [docs/ADR-reconnect-draft.md](docs/ADR-reconnect-draft.md) · [docs/AGENTS-AND-COALESCING.md](docs/AGENTS-AND-COALESCING.md)

## What’s in the tree

| Area | Role |
|------|------|
| Reconnect ladder | WS resume → ICE restart (same PC) → PC recycle → room rejoin last |
| Prefer-audio / L0–L3 | Congestion as **media policy** (`branch=none`), not ICE restart |
| UICoalescing | `ConferenceUIEvent` → per-event model updates → throttled `TileRosterSnapshot` |
| AgentOrchestration | Deterministic agents decide; tools apply (`MediaKnobApplying`) |
| llm-demo/ | Same `apply_media_knobs` surface; offline fixture green without an API key |

## Quick start (iOS)

Requires [XcodeGen](https://github.com/yonaskolb/XcodeGen) and Xcode (iOS 17+).

```bash
xcodegen generate
open WebRTCReconnectMock.xcodeproj
```

Or CLI:

```bash
xcodegen generate
xcodebuild \
  -project WebRTCReconnectMock.xcodeproj \
  -scheme WebRTCReconnectMock \
  -destination 'platform=iOS Simulator,name=iPhone 16' \
  -quiet build
```

1. Run scheme **WebRTCReconnectMock**.
2. Tap **Join** (`mock://local` + local cam/mic when hardware exists; simulator soft-fails without a camera).
3. Use reconnect / congestion controls (table below).
4. Optional research HUD:
   - **Run agent bad-network demo** — network snapshot → knobs → `WebRTCClient` + SoftAssert
   - **Burst UI coalesce demo** — mixed `ConferenceUIEvent` burst → coalesced roster + SoftAssert

Signing: set your own `DEVELOPMENT_TEAM` in `project.yml` (or Xcode) before device runs.

## Quick start (LLM spike, no API key)

```bash
cd llm-demo
python3 agent.py
# → PASS (offline): bad_cell protects audio (L2+ / prefer_audio)
```

With a key (optional): copy `.env.example` → `.env`, set `XAI_API_KEY`, `pip install -r requirements.txt`, then `python3 agent.py` or `--live`. Details: [llm-demo/README.md](llm-demo/README.md).

## Reconnect ladder

1. **WS resume** — `callSessionId` + `cursor` (`lastEventCursor`)
2. **ICE restart** — same `LKRTCPeerConnection`
3. **PC recycle** — escalate after ICE budget / hard reconnect
4. **Room rejoin** — last resort (not the happy path)

Signaling (WS) ≠ media (UDP/ICE/SRTP). Congestion prefer-audio does **not** call ICE restart.

## HUD controls

| Button | Branch | Notes |
|--------|--------|--------|
| **Join** | `idle` | `mock://local`, PC, cam/mic tracks |
| **Force signal drop** | `signal_only` | Signaling-only resume; no ICE restart |
| **Force ICE restart** | `ice_restart` | Same PC; solo mock often completes on **`localOfferApplied`** (setLocal) |
| **Hard reconnect** | `hard_recycle` | New PC, keep `callSessionId`, re-attach tracks |
| **Force Reconnect** | `resume_then_restart` | WS resume then ICE restart |
| **Force congestion** / **Reset L0** / **Prefer audio** | `none` | L0–L3 media policy; pause video send at L2+ |
| **Export Log** | — | ICE/SDP + metrics + StatusLog → share sheet |
| **Run agent bad-network demo** | — | AgentOrchestrator SoftAssert path |
| **Burst UI coalesce demo** | — | ConferenceUIEvent reducer SoftAssert path |

## LiveKit Cloud (optional)

Scheme **LiveKitRoomDemo** uses `client-sdk-swift`. Tokens live under gitignored `secrets/` and `LiveKitRoomDemo/Resources/Tokens.plist` — never commit them. Guide: [docs/LIVEKIT-ROOM-TEST.md](docs/LIVEKIT-ROOM-TEST.md).

`project.yml` pins `webrtc-xcframework` to **exact `150.7871.01`** so SPM can unify with LiveKit SDK. Do not bump WebRTC independently of that pin.

## Layout

```
WebRTCReconnectMock/
├── project.yml
├── README.md
├── docs/           # ADR, agents/coalescing notes, LiveKit room test
├── llm-demo/       # offline/live apply_media_knobs agent
├── Sources/
│   ├── UICoalescing/         # ConferenceUIEvent → TileStateMerger
│   ├── AgentOrchestration/   # agents + tools + SoftAssert
│   ├── WebRTCClient.swift
│   ├── SignalingClient.swift
│   └── …
├── LiveKitRoomDemo/          # optional Cloud room app
└── Resources/Info.plist
```

## Secrets

Do **not** commit:

- `secrets/`
- `LiveKitRoomDemo/Resources/Tokens.plist`
- `.env` / `llm-demo/.env`
- API keys

Already listed in `.gitignore`.

## License

MIT — see `LICENSE`.
