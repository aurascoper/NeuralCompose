#!/usr/bin/env python3
"""
Freeze the Stage 3.4 evidence base — Gate C of Stage 3.4 closure.

Creates Evaluation/stage_3_4/frozen/ containing:
  manifest.json    — every frozen file with size + sha256 + category,
                     plus the registry snapshot and leaderboard heads
  checksums.txt    — shasum -a 256 format, verifiable with `shasum -c`
  provenance.json  — full machine/git/toolchain provenance of the freeze
                     + the validator report that gated it

The evidence files themselves stay in place (results/, corpora/,
Benchmarks/) — the freeze makes them individually read-only and records
their hashes, so any later mutation is detectable by
`shasum -a 256 -c checksums.txt` and by validate_checkpoints.py. Frozen
evidence is NEVER overwritten; a new evaluation campaign appends new files
or bumps fixture versions instead.

Refuses to freeze while:
  - the validator reports any FAIL (warnings allowed — legacy artifacts
    are honest history), or
  - a streaming benchmark is still running (evidence still changing), or
  - Evaluation/stage_3_4/frozen/ already exists (freezes are append-only;
    a re-freeze needs the old freeze moved aside deliberately by a human).

Usage:
  python3 Evaluation/scripts/freeze_stage_3_4.py [--dry-run]
"""
import argparse
import json
import stat
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from provenance import collect_provenance, sha256_file

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
EVAL_DIR = REPO_ROOT / "Evaluation"
FROZEN_DIR = EVAL_DIR / "stage_3_4" / "frozen"

# What counts as Stage 3.4 evidence. Reports and dashboards are
# *documentation about* the evidence (Gate D) and regenerable — not frozen.
EVIDENCE_GLOBS = [
    ("embedding-checkpoints", "Evaluation/results/embeddings/**/*.json"),
    ("embedding-logs", "Evaluation/results/embeddings/*.log"),
    ("generation-checkpoints", "Evaluation/results/candidates/**/*.json"),
    ("generation-logs", "Evaluation/results/candidates/**/*.log"),
    ("aggregates", "Evaluation/results/*.json"),
    ("aggregates", "Evaluation/results/*.csv"),
    ("aggregates", "Evaluation/results/*.md"),
    ("aggregates", "Evaluation/results/embeddings/*.csv"),
    ("aggregates", "Evaluation/results/embeddings/*.md"),
    ("stage-3-4-analyses", "Evaluation/results/stage_3_4/*.json"),
    ("stage-3-4-analyses", "Evaluation/results/stage_3_4/*.md"),
    ("repro", "Evaluation/results/repro/**/*.json"),
    ("repro", "Evaluation/results/repro/*.md"),
    ("plots", "Evaluation/plots/*.png"),
    ("plots", "Evaluation/results/embeddings/plots/*.png"),
    ("corpora", "Evaluation/corpora/*.json"),
    ("corpora", "Evaluation/corpora/MANIFEST.sha256"),
    ("swift-benchmarks", "Benchmarks/*.json"),
]


def benchmark_running():
    try:
        r = subprocess.run(["pgrep", "-f",
                            "streaming_benchmark|embedding_benchmark|GenerationEval|EmbeddingBench"],
                           capture_output=True, text=True, timeout=10)
        return bool(r.stdout.strip())
    except Exception:
        return False


def run_validator():
    import validate_checkpoints as vc
    report = vc.Report(strict=False)
    vc.check_corpora(report)
    vc.check_embedding_checkpoints(report)
    vc.check_generation_checkpoints(report)
    vc.check_embedding_traceability(report)
    vc.check_generation_traceability(report)
    return report


def main():
    parser = argparse.ArgumentParser(description="Freeze Stage 3.4 evidence")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()

    if FROZEN_DIR.exists():
        print(f"REFUSING: {FROZEN_DIR} already exists — freezes are append-only. "
              "A deliberate re-freeze requires a human to move the old freeze aside.")
        sys.exit(1)
    if benchmark_running():
        print("REFUSING: a benchmark process is still running — evidence is "
              "still changing. Freeze only a quiescent evidence base.")
        sys.exit(1)

    validator = run_validator()
    if validator.n_fail:
        print(f"REFUSING: validator reports {validator.n_fail} failure(s). "
              "Frozen evidence must validate clean (warnings for legacy "
              "artifacts are acceptable and recorded).")
        for f in validator.findings:
            if f["level"] == "FAIL":
                print(f"  [{f['category']}] {f['message'][:120]}")
        sys.exit(1)

    files = []
    seen = set()
    for category, pattern in EVIDENCE_GLOBS:
        for path in sorted(REPO_ROOT.glob(pattern)):
            if not path.is_file() or path in seen:
                continue
            seen.add(path)
            rel = path.relative_to(REPO_ROOT)
            files.append({
                "path": str(rel),
                "category": category,
                "bytes": path.stat().st_size,
                "sha256": sha256_file(path),
            })
    if not files:
        print("REFUSING: no evidence files matched — wrong working directory?")
        sys.exit(1)

    print(f"{len(files)} evidence files, "
          f"{sum(f['bytes'] for f in files) / 2**20:.1f} MB")
    if args.dry_run:
        print("[dry-run] no freeze written")
        return

    FROZEN_DIR.mkdir(parents=True)

    # frozen/ sits three levels below the repo root the paths are relative to
    # (frozen → stage_3_4 → Evaluation → root).
    checksums = "\n".join(f"{f['sha256']}  ../../../{f['path']}" for f in files) + "\n"
    (FROZEN_DIR / "checksums.txt").write_text(checksums)

    registry = json.load(open(EVAL_DIR / "corpora" / "hypothesis_registry.json"))
    manifest = {
        "frozen_at": datetime.now(timezone.utc).isoformat(),
        "stage": "3.4",
        "n_files": len(files),
        "total_bytes": sum(f["bytes"] for f in files),
        "hypothesis_registry_snapshot": registry,
        "files": files,
    }
    with open(FROZEN_DIR / "manifest.json", "w") as f:
        json.dump(manifest, f, indent=2)

    provenance = {
        "provenance": collect_provenance(),
        "validator": {
            "n_fail": validator.n_fail,
            "n_warn": validator.n_warn,
            "findings": validator.findings,
        },
    }
    with open(FROZEN_DIR / "provenance.json", "w") as f:
        json.dump(provenance, f, indent=2)

    # Evidence + freeze records become read-only, file by file.
    for entry in files:
        path = REPO_ROOT / entry["path"]
        path.chmod(path.stat().st_mode & ~(stat.S_IWUSR | stat.S_IWGRP | stat.S_IWOTH))
    for name in ("manifest.json", "checksums.txt", "provenance.json"):
        path = FROZEN_DIR / name
        path.chmod(path.stat().st_mode & ~(stat.S_IWUSR | stat.S_IWGRP | stat.S_IWOTH))

    print(f"Frozen: {FROZEN_DIR}")
    print("Verify: cd Evaluation/stage_3_4/frozen && shasum -a 256 -c checksums.txt")


if __name__ == "__main__":
    main()
