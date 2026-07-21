#!/usr/bin/env python3
"""voice-profile.py — write ~/Documents/NeuralCompose/voice-profile.json so the app
auto-selects your Personal Voice + base prosody + authorial register at launch,
with no NEURALCOMPOSE_* env vars.

Session-time / fully offline. Available registers are discovered from the
prose-craft registers dir if present. (A claude-mind persona recall is a
session-time step the assistant does, not this script — the MCP isn't reachable
from plain Python; pass what it surfaces via --register/--rate/etc.)

Examples:
  python Scripts/voice-profile.py --show
  python Scripts/voice-profile.py --use-personal-voice
  python Scripts/voice-profile.py --voice-id com.apple.speech.personalvoice.XXXX --register schopenhauer
  python Scripts/voice-profile.py --rate 0.48 --pitch 0.98 --volume 0.95
"""
import argparse
import json
import sys
from pathlib import Path

CONFIG = Path.home() / "Documents" / "NeuralCompose" / "voice-profile.json"
REGISTERS_DIR = Path.home() / "Developer" / "jobs" / "prose-craft" / "registers"


def load() -> dict:
    if CONFIG.exists():
        try:
            return json.loads(CONFIG.read_text())
        except Exception:
            print(f"warning: existing {CONFIG} unreadable; starting fresh", file=sys.stderr)
    return {}


def registers() -> list:
    if REGISTERS_DIR.is_dir():
        return sorted(p.stem for p in REGISTERS_DIR.glob("*.md")
                      if not p.stem.upper().startswith("PROVENANCE"))
    return []


def main() -> None:
    ap = argparse.ArgumentParser(description="Write NeuralCompose voice-profile.json")
    ap.add_argument("--voice-id", help="AVSpeech voice identifier to pin (e.g. a Personal Voice id)")
    ap.add_argument("--use-personal-voice", dest="use_pv", action="store_true",
                    help="opt into the on-device Personal Voice")
    ap.add_argument("--no-personal-voice", dest="use_pv", action="store_false")
    ap.set_defaults(use_pv=None)
    ap.add_argument("--register", help=f"authorial register; available: {', '.join(registers()) or '(none found)'}")
    ap.add_argument("--rate", type=float, help="base prosody rate 0..1")
    ap.add_argument("--pitch", type=float, help="base pitchMultiplier 0.5..2.0")
    ap.add_argument("--volume", type=float, help="base volume 0..1")
    ap.add_argument("--show", action="store_true", help="print the current profile + available registers, then exit")
    args = ap.parse_args()

    if args.show:
        prof = load()
        print("current voice-profile.json:")
        print(json.dumps(prof, indent=2, sort_keys=True) if prof else "  (none)")
        print("available registers:", ", ".join(registers()) or "(prose-craft registers dir not found)")
        return

    prof = load()
    if args.use_pv is not None:
        prof["usePersonalVoice"] = args.use_pv
    if args.voice_id:
        prof["voiceIdentifier"] = args.voice_id
    if args.register:
        avail = registers()
        if avail and args.register not in avail:
            print(f"warning: register '{args.register}' not in {avail}", file=sys.stderr)
        prof["register"] = args.register
    prosody = prof.get("prosody", {})
    if args.rate is not None:
        prosody["rate"] = args.rate
    if args.pitch is not None:
        prosody["pitchMultiplier"] = args.pitch
    if args.volume is not None:
        prosody["volume"] = args.volume
    if prosody:
        prof["prosody"] = prosody

    CONFIG.parent.mkdir(parents=True, exist_ok=True)
    CONFIG.write_text(json.dumps(prof, indent=2, sort_keys=True) + "\n")
    print(f"wrote {CONFIG}:")
    print(json.dumps(prof, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
