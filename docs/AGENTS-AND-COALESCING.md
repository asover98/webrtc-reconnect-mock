# Agents, tools, and UI coalescing

Notes for the two spikes that sit **on top of** the reconnect ladder. They do not replace signaling, ICE restart, or PC recycle.

## Why bother

Realtime conference UIs fire a lot of small signals (speaking, mute, emoji, join/leave, pin…). Binding SwiftUI to each one causes thrash and races. Separately, media policy under congestion is a decision problem: given a network snapshot, choose knobs (L0–L3 / prefer-audio / pause video send).

This sample splits that into:

1. **Listen** — ingest events / snapshots.
2. **Update a shared model** — one small handler per event (or a pure policy function).
3. **Apply** — throttle a UI snapshot (~1 Hz), or run a tool that touches `WebRTCClient`.

## Agent vs tool

| Role | Responsibility | Examples |
|------|----------------|----------|
| **Agent** | Decide (pure / deterministic) | `NetworkScenarioAgent`, `AnalyticsAgent`, `LayoutAdaptivityAgent` |
| **Tool** | Apply or observe (side effects) | `MediaKnobApplying`, `StatsProviding`, `RosterSnapshotProviding` |

Agents do not call WebRTC APIs directly. Tools wrap existing knobs (`mediaPolicyLevel`, `preferAudio`, stats lines, coalesced roster).

## UI coalescing

High-rate `ConferenceUIEvent` (camera/mic, emoji, chat, join/leave, pin, muted-by-admin, conference mode, speaking/connection/track/reconnect hint) updates `ConferenceRoomState` immediately via per-event `apply*` methods. `TileStateMerger` then emits a `TileRosterSnapshot` at most ~1 Hz (`throttle` + `removeDuplicates`). SoftAsserts exercise the reducers without Combine.

## Agent orchestration (no LLM required)

`AgentOrchestrator` runs a reproducible bad-network path: network fixture → `NetworkScenarioAgent.decide` → `MediaKnobApplying` → analytics report. HUD button **Run agent bad-network demo** wires `WebRTCClientMediaKnobApplier` and logs SoftAssert results.

```swift
let orch = AgentOrchestrator(
    mediaTool: WebRTCClientMediaKnobApplier(client: webRTCClient, statusLog: statusLog),
    statsTool: WebRTCClientStatsProvider(client: webRTCClient)
)
orch.logHandler = { statusLog.append($0) }
let report = orch.runBadNetworkDemo()
```

**Burst UI coalesce demo** feeds a mixed event burst through the same reducers.

## Optional LLM surface (`llm-demo/`)

Python demo uses the **same** `apply_media_knobs` tool shape. Offline mode replays a fixture (no API key). Live mode can fill the decide slot with a model. Goal is comparative: does a tool-calling LLM pick the same audio-protecting knobs as the deterministic agent on `bad_cell`?

## Secrets

Keep `secrets/`, tokens plists, and `.env` gitignored. Never paste live keys into docs.
