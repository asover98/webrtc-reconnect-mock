# LiveKit Cloud room test

Optional check: real two-participant A/V against **your** LiveKit Cloud project.
This is **not** the reconnect-ladder HUD mock — different purpose.

**URL:** your project WebSocket URL (`wss://…livekit.cloud`)  
**Tokens:** `secrets/livekit-tokens.json` (gitignored) — fields `iphoneToken`, `simulatorToken` (unique identities). Mint with ≥24h TTL; regenerate if expired.

---

## A) Quick test WITHOUT our Xcode app (meet.livekit.io)

Official Meet example supports a **Custom** connection with Cloud URL + JWT.

### Option 1 — Custom tab (manual paste)

1. On **Mac Chrome**: open [https://meet.livekit.io](https://meet.livekit.io).
2. Open the **Custom** tab (not the LiveKit Cloud demo tab).
3. Paste your **LiveKit URL** and `simulatorToken`.
4. Connect / Join (allow camera + mic).
5. On **iPhone Safari**: same Meet → **Custom**, same URL, `iphoneToken` (different identity).
6. Connect. You should see two participants with real A/V.

### Option 2 — Direct custom deep link

`https://meet.livekit.io/custom?liveKitUrl=<urlencoded-wss>&token=<JWT>`

1. Build two URLs — one with `simulatorToken`, one with `iphoneToken`.
2. Open the simulator URL in **Mac Chrome**, the iPhone URL in **Safari**.
3. Allow camera/mic when prompted.

**Do not** put the API secret in the browser. Tokens only.

---

## B) What we measure there

| Check | How |
|--------|-----|
| Real SFU join | Both identities appear in the same room |
| Two-way A/V | Camera + mic from phone and Mac (or second browser) |
| Network toggle | On phone: Control Center → Airplane / Wi‑Fi off→on; watch media recovery in Meet UI |
| Identity isolation | Each token has a unique `identity` |

This validates **Cloud room + media path**, not this app’s reconnect-ladder timings.

---

## C) Relation to the mock

| Surface | Purpose |
|---------|---------|
| `WebRTCReconnectMock` | Ladder timings / StatusLog export over `mock://local` |
| meet.livekit.io + tokens | Real LiveKit Cloud A/V + network toggle |
| `LiveKitRoomDemo` (if present) | Same Cloud room inside a thin SwiftUI shell |

Keep them separate: mock = recovery strategy research; Meet/demo = real SFU media.
