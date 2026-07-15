#!/usr/bin/env python3
"""
Freeze the evaluation corpora — Gate C of Stage 3.4 closure.

Writes Evaluation/corpora/MANIFEST.sha256 (shasum -a 256 format) over every
corpus fixture, then removes write permission from the manifested files.
Corpora are versioned-immutable: a change means a NEW _vN+1 file, never an
edit — freeze_corpora.py hard-fails if a manifested file's hash changed.

hypothesis_registry.json is deliberately NOT manifested: it is a live
registry (run_stage_3_4.py rewrites statuses; Stage 3.5 sections keep
evolving). Its Stage 3.4 snapshot is frozen by freeze_stage_3_4.py instead.

Usage:
  python3 Evaluation/scripts/freeze_corpora.py [--allow-refreeze]

Verify anytime:
  cd Evaluation/corpora && shasum -a 256 -c MANIFEST.sha256
"""
import argparse
import os
import stat
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from provenance import sha256_file

CORPORA_DIR = Path(__file__).resolve().parent.parent / "corpora"
MANIFEST_PATH = CORPORA_DIR / "MANIFEST.sha256"
EXCLUDED = {"hypothesis_registry.json"}


def load_manifest():
    entries = {}
    if MANIFEST_PATH.exists():
        for line in MANIFEST_PATH.read_text().splitlines():
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            digest, name = line.split(None, 1)
            entries[name.lstrip("*")] = digest
    return entries


def main():
    parser = argparse.ArgumentParser(description="Freeze evaluation corpora")
    parser.add_argument("--allow-refreeze", action="store_true",
                        help="Permit re-manifesting a file whose hash changed. "
                             "Should essentially never be used — corpora are "
                             "versioned-immutable.")
    args = parser.parse_args()

    existing = load_manifest()
    entries = {}
    violations = []
    for path in sorted(CORPORA_DIR.glob("*.json")):
        if path.name in EXCLUDED:
            continue
        digest = sha256_file(path)
        if path.name in existing and existing[path.name] != digest:
            violations.append(path.name)
        entries[path.name] = digest

    if violations and not args.allow_refreeze:
        print("REFUSING to freeze — manifested corpora changed on disk:")
        for name in violations:
            print(f"  {name}")
        print("Corpora are versioned-immutable: create a _vN+1 file instead. "
              "(--allow-refreeze overrides; don't.)")
        sys.exit(1)

    lines = ["# Evaluation corpora manifest — versioned-immutable.",
             "# Verify: cd Evaluation/corpora && shasum -a 256 -c MANIFEST.sha256",
             "# hypothesis_registry.json excluded by design (live registry)."]
    lines += [f"{digest}  {name}" for name, digest in entries.items()]
    MANIFEST_PATH.write_text("\n".join(lines) + "\n")
    print(f"Wrote {MANIFEST_PATH} ({len(entries)} files)")

    for name in entries:
        path = CORPORA_DIR / name
        mode = path.stat().st_mode
        path.chmod(mode & ~(stat.S_IWUSR | stat.S_IWGRP | stat.S_IWOTH))
    print("Write permission removed from manifested corpora.")


if __name__ == "__main__":
    main()
