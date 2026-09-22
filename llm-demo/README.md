# LLM media-policy agent (Grok / xAI)

**Useful goal (not chat-for-chat):** given a **call-quality snapshot** (RTT, loss, bandwidth, path flags), choose **media knobs** (L0–L3 / preferAudio / pause video) via tool `apply_media_knobs`. Compare to the deterministic `NetworkScenarioAgent` thresholds from the iOS mock. Measurable outcome: *did we protect audio under bad cell?*

## Offline by default (no API key)

```bash
python3 agent.py
```

No `XAI_API_KEY` → **offline mode**: recorded tool-call JSON is replayed through the **same** `knobs_from_tool_args` parser and SoftAssert checks as live. Exit code 0 if `bad_cell` protects audio (L2+, prefer_audio, pause_video_send).

Intentional default: clone → run → green, without billing or secrets. The live path is the same code with the decide slot filled by Grok instead of `fixtures/*.json`.

```bash
python3 agent.py --offline   # force replay even if a key is present
python3 agent.py --live      # require API key; fail if missing
```

## Live (optional)

1. Key at [console.x.ai](https://console.x.ai) (credits; not unlimited consumer Grok chat).
2. `cp .env.example .env` → `XAI_API_KEY=...` (gitignored).
3. `python3 -m venv .venv && source .venv/bin/activate && pip install -r requirements.txt`
4. `python3 agent.py` — live tool-calling for `bad_cell` + `healthy`.

## What “success” looks like

- A **tool-shaped** `apply_media_knobs` decision (not only prose).
- For `bad_cell`: level ≥ 2, `prefer_audio=true`, `pause_video_send=true`.
- For `healthy`: level 0 (or soft mismatch logged).
- Exit code 0 when bad-cell policy passes.

## Relation to iOS mock

| Swift | This demo |
|-------|-----------|
| `NetworkScenarioAgent.decide` | Grok tools **or** offline replay |
| `MediaKnobApplying` | `knobs_from_tool_args` |
| `AgentOrchestrator.runBadNetworkDemo` | `agent.py` fixtures |

No LiveKit secrets here. Do not commit API keys.
