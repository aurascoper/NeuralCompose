#!/usr/bin/env python3
"""
run-session-protocol.py — guided cue helper for a capture session.

Runs ALONGSIDE the NeuralCompose app's recording (it does not touch the EEG
stream or hardware). It walks you through a segmented protocol with countdown
timers and blink-tag reminders, and logs every transition to a JSON file so the
next-day consumer (consume-session.py) can reconcile the segments it recovers
from the raw EEG against your intended timeline.

Sync model: the *primary* segment markers are the 5-hard-blink bursts the
consumer detects directly in the EEG (robust to clock offset). This log's
timestamps are a secondary cross-check — recorded in BOTH ISO wall-clock and
Unix-epoch seconds, since Muse eeg.csv `t_seconds` is Unix-epoch.

Usage:
  ./Scripts/run-session-protocol.py                       # default: focus 10m, drowsy 10m, sleep (until Ctrl-C)
  ./Scripts/run-session-protocol.py --segments focus:600 drowsy:600 sleep:0
  ./Scripts/run-session-protocol.py --tag-blinks 5 --tag-window 8
  ./Scripts/run-session-protocol.py --dry-run             # fast-forward timers (no real waits)
"""
from __future__ import annotations

import argparse
import json
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

RECORDINGS_BASE = Path.home() / "Documents" / "NeuralCompose" / "Recordings"
DEFAULT_SEGMENTS = [("focus", 600), ("drowsy", 600), ("sleep", 0)]  # 0 = until interrupted


def _now() -> tuple[str, float]:
    t = time.time()
    return datetime.fromtimestamp(t, timezone.utc).isoformat(), t


def _countdown(seconds: float, label: str, dry_run: bool) -> None:
    """Sleep `seconds`, printing a coarse remaining-time line. 0 => until Ctrl-C."""
    if dry_run:
        return
    if seconds <= 0:
        print(f"    [{label}] running until you press Ctrl-C …")
        try:
            while True:
                time.sleep(30)
        except KeyboardInterrupt:
            print(f"\n    [{label}] stopped.")
        return
    remaining = seconds
    step = 30.0 if seconds > 60 else 5.0
    try:
        while remaining > 0:
            mins, secs = divmod(int(remaining), 60)
            print(f"    [{label}] {mins:02d}:{secs:02d} remaining", end="\r", flush=True)
            time.sleep(min(step, remaining))
            remaining -= step
        print(f"    [{label}] done.                      ")
    except KeyboardInterrupt:
        print(f"\n    [{label}] skipped by user.")


def parse_segments(specs: list[str]) -> list[tuple[str, int]]:
    out = []
    for spec in specs:
        if ":" not in spec:
            raise SystemExit(f"bad --segments entry {spec!r}; expected label:seconds")
        label, secs = spec.rsplit(":", 1)
        out.append((label, int(secs)))
    return out


def run_protocol(segments: list[tuple[str, int]], *, tag_blinks: int, tag_window: float,
                 out_dir: Path, dry_run: bool) -> dict:
    created_iso, created_unix = _now()
    log = {
        "created_iso": created_iso,
        "created_unix": created_unix,
        "tag_blinks": tag_blinks,
        "tag_window_s": tag_window,
        "dry_run": dry_run,
        "segments": [],
    }
    out_dir.mkdir(parents=True, exist_ok=True)
    out_path = out_dir / f"protocol-{datetime.fromtimestamp(created_unix).strftime('%Y%m%d-%H%M%S')}.json"

    def _save() -> None:
        out_path.write_text(json.dumps(log, indent=2))

    print("=== NeuralCompose Session Protocol ===")
    print(f"Make sure the app is already recording. Logging to {out_path}")
    print(f"Each segment starts with a {tag_blinks}-hard-blink tag (blink window {tag_window:.0f}s).\n")
    try:
        for label, seconds in segments:
            cue_iso, cue_unix = _now()
            print(f"» {label.upper()}: blink HARD {tag_blinks}× NOW to tag the start.")
            if not dry_run:
                time.sleep(tag_window)
            start_iso, start_unix = _now()
            dur_txt = "until Ctrl-C" if seconds <= 0 else f"{seconds // 60}m{seconds % 60:02d}s"
            print(f"  {label} running ({dur_txt}) …")
            log["segments"].append({
                "label": label,
                "cue_iso": cue_iso, "cue_unix": cue_unix,
                "start_iso": start_iso, "start_unix": start_unix,
                "planned_duration_s": seconds,
            })
            _save()  # persist after each transition so a crash/Ctrl-C keeps progress
            _countdown(seconds, label, dry_run)
    except KeyboardInterrupt:
        print("\nProtocol interrupted — saving progress.")
    finally:
        ended_iso, ended_unix = _now()
        log["ended_iso"], log["ended_unix"] = ended_iso, ended_unix
        _save()
    print(f"\nSaved protocol log: {out_path}")
    return {"log": log, "path": str(out_path)}


def main() -> None:
    ap = argparse.ArgumentParser(description="Guided cue helper for a capture session")
    ap.add_argument("--segments", nargs="*", default=None,
                    help="label:seconds entries (default: focus:600 drowsy:600 sleep:0)")
    ap.add_argument("--tag-blinks", type=int, default=5)
    ap.add_argument("--tag-window", type=float, default=8.0, help="seconds to perform the blink tag")
    ap.add_argument("--out-dir", type=Path, default=RECORDINGS_BASE)
    ap.add_argument("--dry-run", action="store_true", help="fast-forward all timers (no real waits)")
    args = ap.parse_args()

    segments = parse_segments(args.segments) if args.segments else DEFAULT_SEGMENTS
    run_protocol(segments, tag_blinks=args.tag_blinks, tag_window=args.tag_window,
                 out_dir=args.out_dir, dry_run=args.dry_run)


if __name__ == "__main__":
    main()
