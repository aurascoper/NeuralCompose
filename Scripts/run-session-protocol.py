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
  python3 Scripts/run-session-protocol.py                       # default: focus 10m, drowsy 10m, sleep (until Ctrl-C)
  python3 Scripts/run-session-protocol.py --segments focus:600 drowsy:600 sleep:0
  python3 Scripts/run-session-protocol.py --preset encoder-pilot
  python3 Scripts/run-session-protocol.py --tag-blinks 5 --tag-window 8
  python3 Scripts/run-session-protocol.py --dry-run             # fast-forward timers (no real waits)
"""
from __future__ import annotations

import argparse
import hashlib
import json
import time
from datetime import datetime, timezone
from pathlib import Path

RECORDINGS_BASE = Path.home() / "Documents" / "NeuralCompose" / "Recordings"
PROTOCOL_SCHEMA = "nc-eeg-observable-protocol-v1"
ROOT = Path(__file__).resolve().parents[1]
ENCODER_PILOT_SPEC_PATH = ROOT / "NeuralComposeEEG" / "configs" / "observable-protocol-v1.json"
OVERNIGHT_SEGMENTS = [("focus", 600), ("drowsy", 600), ("sleep", 0)]  # 0 = until interrupted


def _sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def load_encoder_pilot_spec() -> dict:
    try:
        spec = json.loads(ENCODER_PILOT_SPEC_PATH.read_text())
    except (OSError, json.JSONDecodeError) as exc:
        raise SystemExit(f"cannot load encoder-pilot specification: {exc}") from exc
    if spec.get("schema_version") != "nc-eeg-observable-protocol-spec-v1":
        raise SystemExit("encoder-pilot specification has the wrong schema")
    if spec.get("protocol_id") != "encoder-pilot-v1":
        raise SystemExit("encoder-pilot specification has the wrong protocol id")
    segments = spec.get("segments")
    if not isinstance(segments, list) or not segments:
        raise SystemExit("encoder-pilot specification needs segments")
    for segment in segments:
        if not isinstance(segment, dict) or not isinstance(segment.get("label"), str):
            raise SystemExit("encoder-pilot specification has an invalid segment")
        if not isinstance(segment.get("duration_seconds"), int) or segment["duration_seconds"] <= 0:
            raise SystemExit("encoder-pilot segment durations must be positive integers")
        if not isinstance(segment.get("instruction"), str) or not segment["instruction"]:
            raise SystemExit("encoder-pilot segments need instructions")
    return spec


ENCODER_PILOT_SPEC = load_encoder_pilot_spec()
ENCODER_PILOT_SEGMENTS = [(segment["label"], segment["duration_seconds"]) for segment in ENCODER_PILOT_SPEC["segments"]]
ENCODER_PILOT_INSTRUCTIONS = {segment["label"]: segment["instruction"] for segment in ENCODER_PILOT_SPEC["segments"]}
PRESETS = {"overnight": OVERNIGHT_SEGMENTS, "encoder-pilot": ENCODER_PILOT_SEGMENTS}


def encoder_pilot_context(*, listening_audio: Path, listening_audio_id: str) -> dict:
    """Bind the operator-selected audio and pinned count script to one log."""
    if not listening_audio_id.strip():
        raise SystemExit("--listening-audio-id is required for encoder-pilot")
    if not listening_audio.is_file():
        raise SystemExit("--listening-audio must name a readable immutable local audio asset")
    speaking = ENCODER_PILOT_SPEC["speaking_script"]
    speaking_path = ENCODER_PILOT_SPEC_PATH.parent / speaking["relative_path"]
    if not speaking_path.is_file():
        raise SystemExit(f"encoder-pilot speaking script is missing: {speaking_path}")
    return {
        "protocol_preset": ENCODER_PILOT_SPEC["protocol_id"],
        "protocol_preset_sha256": _sha256_file(ENCODER_PILOT_SPEC_PATH),
        "protocol_cue_clock": ENCODER_PILOT_SPEC["protocol_cue_clock"],
        "transition_gap_seconds": ENCODER_PILOT_SPEC["transition_gap_seconds"],
        "listening_audio_id": listening_audio_id,
        "listening_audio_sha256": _sha256_file(listening_audio),
        "speaking_script_id": speaking["id"],
        "speaking_script_sha256": _sha256_file(speaking_path),
    }


def _now() -> tuple[str, float]:
    t = time.time()
    return datetime.fromtimestamp(t, timezone.utc).isoformat(), t


def _countdown(seconds: float, label: str, dry_run: bool) -> str:
    """Run one block and return its actual completion state."""
    if dry_run:
        return "completed"
    if seconds <= 0:
        print(f"    [{label}] running until you press Ctrl-C …")
        try:
            while True:
                time.sleep(30)
        except KeyboardInterrupt:
            print(f"\n    [{label}] stopped.")
        return "interrupted"
    remaining = seconds
    step = 30.0 if seconds > 60 else 5.0
    try:
        while remaining > 0:
            mins, secs = divmod(int(remaining), 60)
            print(f"    [{label}] {mins:02d}:{secs:02d} remaining", end="\r", flush=True)
            time.sleep(min(step, remaining))
            remaining -= step
        print(f"    [{label}] done.                      ")
        return "completed"
    except KeyboardInterrupt:
        print(f"\n    [{label}] skipped by user.")
        return "interrupted"


def parse_segments(specs: list[str]) -> list[tuple[str, int]]:
    out = []
    for spec in specs:
        if ":" not in spec:
            raise SystemExit(f"bad --segments entry {spec!r}; expected label:seconds")
        label, secs = spec.rsplit(":", 1)
        out.append((label, int(secs)))
    return out


def resolve_segments(specs: list[str] | None, preset: str) -> list[tuple[str, int]]:
    """Use explicit segments when present; otherwise use a named safe preset."""
    if specs is not None:
        parsed = parse_segments(specs)
        if not parsed:
            raise SystemExit("--segments requires at least one label:seconds entry")
        return parsed
    return list(PRESETS[preset])


def run_protocol(segments: list[tuple[str, int]], *, tag_blinks: int, tag_window: float,
                 out_dir: Path, dry_run: bool, protocol_id: str = "custom-v1",
                 protocol_context: dict | None = None) -> dict:
    created_iso, created_unix = _now()
    log = {
        "schema_version": PROTOCOL_SCHEMA,
        "protocol_id": protocol_id,
        "created_iso": created_iso,
        "created_unix": created_unix,
        "tag_blinks": tag_blinks,
        "tag_window_s": tag_window,
        "dry_run": dry_run,
        "segments": [],
    }
    if protocol_context:
        log.update(protocol_context)
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
            instruction = ENCODER_PILOT_INSTRUCTIONS.get(label)
            if instruction:
                print(f"  Activity: {instruction}")
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
                "instruction": instruction,
            })
            _save()  # persist after each transition so a crash/Ctrl-C keeps progress
            completion = _countdown(seconds, label, dry_run)
            end_iso, end_unix = _now()
            log["segments"][-1].update({
                "end_iso": end_iso,
                "end_unix": end_unix,
                "actual_duration_s": max(0.0, end_unix - start_unix),
                "completion": completion,
            })
            _save()
            if completion != "completed":
                print("Protocol stopped before the next block; this capture is intentionally ineligible for EXP-NC-EEG-ENC-001.")
                break
    except KeyboardInterrupt:
        print("\nProtocol interrupted — saving progress.")
    finally:
        ended_iso, ended_unix = _now()
        log["ended_iso"], log["ended_unix"] = ended_iso, ended_unix
        log["completed"] = len(log["segments"]) == len(segments) and all(
            segment.get("completion") == "completed" for segment in log["segments"]
        )
        _save()
    print(f"\nSaved protocol log: {out_path}")
    return {"log": log, "path": str(out_path)}


def main() -> None:
    ap = argparse.ArgumentParser(description="Guided cue helper for a capture session")
    ap.add_argument("--segments", nargs="*", default=None,
                    help="label:seconds entries (overrides --preset)")
    ap.add_argument("--preset", choices=tuple(PRESETS), default="overnight",
                    help="named segment sequence (default: overnight)")
    ap.add_argument("--tag-blinks", type=int, default=5)
    ap.add_argument("--tag-window", type=float, default=8.0, help="seconds to perform the blink tag")
    ap.add_argument("--listening-audio", type=Path, help="immutable local audio asset required by encoder-pilot")
    ap.add_argument("--listening-audio-id", help="stable identifier for --listening-audio")
    ap.add_argument("--out-dir", type=Path, default=RECORDINGS_BASE)
    ap.add_argument("--dry-run", action="store_true", help="fast-forward all timers (no real waits)")
    args = ap.parse_args()

    segments = resolve_segments(args.segments, args.preset)
    protocol_id = f"{args.preset}-v1" if args.segments is None else "custom-v1"
    protocol_context = None
    if args.preset == "encoder-pilot" and args.segments is None:
        if args.tag_blinks != ENCODER_PILOT_SPEC["tag_blinks"]:
            raise SystemExit("encoder-pilot requires the pinned tag-blink count")
        if args.tag_window != ENCODER_PILOT_SPEC["transition_gap_seconds"]:
            raise SystemExit("encoder-pilot requires the pinned transition gap")
        if args.listening_audio is None or args.listening_audio_id is None:
            raise SystemExit("encoder-pilot requires --listening-audio and --listening-audio-id")
        protocol_context = encoder_pilot_context(
            listening_audio=args.listening_audio,
            listening_audio_id=args.listening_audio_id,
        )
    run_protocol(segments, tag_blinks=args.tag_blinks, tag_window=args.tag_window,
                 out_dir=args.out_dir, dry_run=args.dry_run, protocol_id=protocol_id,
                 protocol_context=protocol_context)


if __name__ == "__main__":
    main()
