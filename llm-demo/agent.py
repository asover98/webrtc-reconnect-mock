#!/usr/bin/env python3
"""Media-policy agent: call-quality snapshot → apply_media_knobs (tool-calling).

Same pipeline with or without an API key:
  - live:  Grok/xAI must emit tool call apply_media_knobs
  - offline: recorded tool-call JSON is replayed through the SAME parser/asserts

Useful outcome: adaptive media policy (protect audio on bad cell), comparable
to the iOS NetworkScenarioAgent — not a chatbot demo.
"""
from __future__ import annotations

import argparse
import json
import os
import sys
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any

HERE = Path(__file__).resolve().parent

try:
    from dotenv import load_dotenv

    load_dotenv(HERE / ".env")
except ImportError:
    pass

API_KEY = os.getenv("XAI_API_KEY") or os.getenv("GROK_API_KEY")
MODEL = os.getenv("XAI_MODEL", "grok-4-fast-reasoning")
BASE_URL = "https://api.x.ai/v1"


@dataclass
class MediaKnobs:
    level: int
    prefer_audio: bool
    pause_video_send: bool
    pause_video_recv: bool
    reason: str


def deterministic_decide(snap: dict[str, Any]) -> MediaKnobs:
    """Baseline mirroring Swift NetworkScenarioAgent thresholds (loosely)."""
    if not snap.get("path_satisfied", True):
        return MediaKnobs(3, True, True, True, "path_unsatisfied")
    loss = float(snap.get("loss_percent") or 0)
    rtt = float(snap.get("rtt_ms") or 0)
    bw = float(snap.get("estimated_bandwidth_kbps") or 9999)
    if loss >= 12 or rtt >= 500 or bw <= 150:
        return MediaKnobs(3, True, True, True, "severe_congestion")
    if loss >= 5 or rtt >= 300 or bw <= 400 or snap.get("is_constrained"):
        return MediaKnobs(2, True, True, False, "protect_audio")
    if loss >= 2 or rtt >= 150:
        return MediaKnobs(1, False, False, False, "layer_drop")
    return MediaKnobs(0, False, False, False, "full_av")


FIXTURES: dict[str, dict[str, Any]] = {
    "bad_cell": {
        "path_satisfied": True,
        "is_expensive": True,
        "is_constrained": True,
        "rtt_ms": 380,
        "loss_percent": 8.5,
        "estimated_bandwidth_kbps": 180,
    },
    "healthy": {
        "path_satisfied": True,
        "is_expensive": False,
        "is_constrained": False,
        "rtt_ms": 40,
        "loss_percent": 0.2,
        "estimated_bandwidth_kbps": 2500,
    },
}

# Recorded tool-call arguments (what a live model is expected to emit).
# Offline mode feeds these through the same knobs_from_tool_args() path.
REPLAY_TOOL_ARGS: dict[str, dict[str, Any]] = {
    "bad_cell": {
        "level": 2,
        "prefer_audio": True,
        "pause_video_send": True,
        "pause_video_recv": False,
        "reason": "high_rtt_and_loss_protect_audio",
    },
    "healthy": {
        "level": 0,
        "prefer_audio": False,
        "pause_video_send": False,
        "pause_video_recv": False,
        "reason": "healthy_full_av",
    },
}

TOOLS = [
    {
        "type": "function",
        "function": {
            "name": "apply_media_knobs",
            "description": (
                "Apply conference media degradation policy. "
                "Use when network quality requires protecting audio by reducing/pausing video. "
                "level 0=full A/V, 1=light degrade, 2=pause video send + prefer audio, "
                "3=aggressive pause send+recv video."
            ),
            "parameters": {
                "type": "object",
                "properties": {
                    "level": {"type": "integer", "minimum": 0, "maximum": 3},
                    "prefer_audio": {"type": "boolean"},
                    "pause_video_send": {"type": "boolean"},
                    "pause_video_recv": {"type": "boolean"},
                    "reason": {"type": "string"},
                },
                "required": [
                    "level",
                    "prefer_audio",
                    "pause_video_send",
                    "pause_video_recv",
                    "reason",
                ],
            },
        },
    }
]

SYSTEM = (
    "You are a realtime conference media-policy agent. "
    "You MUST call apply_media_knobs exactly once based on the call-quality snapshot. "
    "Do not ask questions. Prefer protecting audio under congestion; do not recommend ICE restart."
)


def knobs_from_tool_args(args: dict[str, Any]) -> MediaKnobs:
    """Shared parser: live tool_call.arguments JSON and offline replay both land here."""
    return MediaKnobs(
        level=int(args["level"]),
        prefer_audio=bool(args["prefer_audio"]),
        pause_video_send=bool(args["pause_video_send"]),
        pause_video_recv=bool(args["pause_video_recv"]),
        reason=str(args.get("reason") or ""),
    )


def run_offline(name: str, snap: dict[str, Any]) -> tuple[MediaKnobs, MediaKnobs, str]:
    baseline = deterministic_decide(snap)
    recorded = REPLAY_TOOL_ARGS[name]
    raw = json.dumps(recorded)
    # Same shape a live completion would hand us after tool_calls[0].function.arguments
    applied = knobs_from_tool_args(json.loads(raw))
    return applied, baseline, raw


def run_live(client: Any, name: str, snap: dict[str, Any]) -> tuple[MediaKnobs | None, MediaKnobs, str]:
    baseline = deterministic_decide(snap)
    user = (
        f"Fixture={name}. Call-quality snapshot JSON:\n"
        f"{json.dumps(snap, indent=2)}\n"
        "Choose media knobs via the apply_media_knobs tool."
    )
    resp = client.chat.completions.create(
        model=MODEL,
        messages=[
            {"role": "system", "content": SYSTEM},
            {"role": "user", "content": user},
        ],
        tools=TOOLS,
        tool_choice="auto",
        temperature=0,
    )
    msg = resp.choices[0].message
    applied: MediaKnobs | None = None
    raw = ""
    if msg.tool_calls:
        for tc in msg.tool_calls:
            if tc.function.name != "apply_media_knobs":
                continue
            args = json.loads(tc.function.arguments)
            applied = knobs_from_tool_args(args)
            raw = tc.function.arguments
            break
    else:
        raw = msg.content or "(no tool call)"
    return applied, baseline, raw


def assert_bad_cell(knobs: MediaKnobs) -> list[str]:
    fails = []
    if knobs.level < 2:
        fails.append(f"expected level>=2, got {knobs.level}")
    if not knobs.prefer_audio:
        fails.append("expected prefer_audio=true")
    if not knobs.pause_video_send:
        fails.append("expected pause_video_send=true")
    return fails


def write_fixture_files() -> None:
    """Keep fixtures/ in sync for readers who open JSON instead of the .py dict."""
    out = HERE / "fixtures"
    out.mkdir(exist_ok=True)
    for name, snap in FIXTURES.items():
        payload = {
            "snapshot": snap,
            "recorded_tool_call": {
                "name": "apply_media_knobs",
                "arguments": REPLAY_TOOL_ARGS[name],
            },
            "deterministic": asdict(deterministic_decide(snap)),
        }
        (out / f"{name}.json").write_text(json.dumps(payload, indent=2) + "\n")


def main() -> int:
    parser = argparse.ArgumentParser(description="LLM / offline media-policy agent demo")
    parser.add_argument(
        "--offline",
        action="store_true",
        help="Force offline replay even if XAI_API_KEY is set",
    )
    parser.add_argument(
        "--live",
        action="store_true",
        help="Require live API (fail if no key)",
    )
    args = parser.parse_args()

    write_fixture_files()

    use_offline = args.offline or not API_KEY
    if args.live and not API_KEY:
        print("Missing XAI_API_KEY (or GROK_API_KEY). Copy .env.example → .env")
        print("Or run without --live to use offline fixture replay.")
        return 2

    if use_offline:
        mode = "offline (fixture / recorded tool-call replay)"
        print(f"mode={mode}")
        if not API_KEY and not args.offline:
            print("note: no XAI_API_KEY — live Grok skipped; same tool parser + asserts.")
        print("Goal: tool-shaped apply_media_knobs for adaptive media policy.\n")
        client = None
    else:
        try:
            from openai import OpenAI
        except ImportError:
            print("pip install -r requirements.txt  (needed for live mode)")
            return 2
        client = OpenAI(api_key=API_KEY, base_url=BASE_URL)
        print(f"mode=live model={MODEL} base={BASE_URL}")
        print("Goal: LLM tool-calls apply_media_knobs for adaptive media policy.\n")

    exit_code = 0
    for name, snap in FIXTURES.items():
        print(f"=== {name} ===")
        try:
            if use_offline:
                applied, baseline, raw = run_offline(name, snap)
            else:
                applied, baseline, raw = run_live(client, name, snap)
        except Exception as e:
            print(f"error: {e}")
            return 1
        print(f"deterministic: {asdict(baseline)}")
        if applied is None:
            print(f"LLM: NO tool call — {raw[:200]}")
            exit_code = 1
            continue
        label = "replay tool:" if use_offline else "LLM tool:  "
        print(f"{label}     {asdict(applied)}")
        print(f"raw args:       {raw}")
        if name == "bad_cell":
            fails = assert_bad_cell(applied)
            if fails:
                print("ASSERT FAIL:", "; ".join(fails))
                exit_code = 1
            else:
                print("ASSERT OK: bad_cell protects audio (L2+)")
        if name == "healthy" and applied.level >= 2:
            print("NOTE: healthy got L2+ — soft mismatch vs deterministic L0")
        print()

    if exit_code == 0:
        print("PASS: harness green" + (" (offline)" if use_offline else " (live)"))
    return exit_code


if __name__ == "__main__":
    sys.exit(main())
