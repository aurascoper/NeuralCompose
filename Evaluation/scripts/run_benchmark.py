#!/usr/bin/env python3
"""
Benchmark orchestration: discovers models, runs the GenerationEval Swift
binary, collects raw results, and emits them for downstream analysis.

Usage:
    python3 Evaluation/scripts/run_benchmark.py [--candidates V1|V2] [--binary PATH]

Discovers model directories under Models/, matches them against the
candidates fixture, and runs the GenerationEval executable. If a model
isn't downloaded, it's automatically skipped (the Swift harness already
handles this, but we also report it here for visibility).

Output:
    Evaluation/results/raw.json   — raw per-candidate, per-prompt results
    Evaluation/results/run_meta.json — run metadata (timestamp, git SHA, device)
"""
import argparse
import json
import os
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from provenance import collect_provenance, sha256_file

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
EVAL_DIR = REPO_ROOT / "Evaluation"
MODELS_DIR = REPO_ROOT / "Models"
RESULTS_DIR = EVAL_DIR / "results"
CORPORA_DIR = EVAL_DIR / "corpora"


def discover_model_dirs():
    """Return set of leaf directory names under Models/."""
    if not MODELS_DIR.exists():
        return set()
    return {d.name for d in MODELS_DIR.iterdir() if d.is_dir() and not d.name.startswith(".")}


def load_candidates(version="v2"):
    fixture_path = CORPORA_DIR / f"generation_eval_candidates_{version}.json"
    if not fixture_path.exists():
        # Fall back to v1
        fixture_path = CORPORA_DIR / "generation_eval_candidates_v1.json"
    with open(fixture_path) as f:
        return json.load(f)


def find_binary():
    """Find the GenerationEval binary — prefer Xcode build, then swift build."""
    candidates = [
        REPO_ROOT / ".build/xcode/Build/Products/Debug/GenerationEval",
        REPO_ROOT / ".build/xcode/Build/Products/Release/GenerationEval",
        REPO_ROOT / ".build/debug/GenerationEval",
        REPO_ROOT / ".build/release/GenerationEval",
    ]
    for p in candidates:
        if p.exists() and os.access(p, os.X_OK):
            return p
    return None


def git_sha():
    try:
        result = subprocess.run(
            ["git", "rev-parse", "HEAD"],
            capture_output=True, text=True, cwd=REPO_ROOT, timeout=5
        )
        return result.stdout.strip() if result.returncode == 0 else "unknown"
    except Exception:
        return "unknown"


def main():
    parser = argparse.ArgumentParser(description="Run NeuralCompose generation benchmark")
    parser.add_argument("--candidates", default="v3", choices=["v1", "v2", "v3"],
                        help="Candidates fixture version")
    parser.add_argument("--binary", default=None, help="Path to GenerationEval binary")
    parser.add_argument("--output-dir", default=str(RESULTS_DIR),
                        help="Output directory for results")
    args = parser.parse_args()

    results_dir = Path(args.output_dir)
    results_dir.mkdir(parents=True, exist_ok=True)

    # Discover available models
    available = discover_model_dirs()
    candidates_data = load_candidates(args.candidates)

    print("=== NeuralCompose Generation Benchmark ===")
    print(f"Candidates fixture: v{candidates_data['version']}")
    print(f"Models directory: {MODELS_DIR}")
    print(f"Available models on disk: {sorted(available)}")
    print()

    # Check which candidates are available
    for c in candidates_data["candidates"]:
        status = "AVAILABLE" if c["directory"] in available else "MISSING (will skip)"
        print(f"  {c['name']:25s} {c['directory']:40s} {status}")
    print()

    # Find binary
    binary = Path(args.binary) if args.binary else find_binary()
    if binary is None or not binary.exists():
        print("ERROR: GenerationEval binary not found.")
        print("Build it first with:")
        print("  xcodebuild -scheme GenerationEval -destination 'platform=macOS' "
              "-derivedDataPath .build/xcode build")
        print("  # or: swift build --product GenerationEval")
        sys.exit(1)

    print(f"Binary: {binary}")
    print()

    # Run the Swift harness
    start_time = time.time()
    print("Running GenerationEval...")
    proc = subprocess.run(
        [str(binary)],
        capture_output=True, text=True, cwd=str(REPO_ROOT), timeout=600
    )
    elapsed = time.time() - start_time

    if proc.returncode != 0:
        print(f"GenerationEval exited with code {proc.returncode}")
        print("STDERR:", proc.stderr[-2000:] if proc.stderr else "(empty)")
        sys.exit(1)

    print(f"GenerationEval completed in {elapsed:.1f}s")
    if proc.stderr:
        # Print any stderr notes (model skip messages etc.)
        for line in proc.stderr.strip().split("\n")[-10:]:
            print(f"  [stderr] {line}")

    # Find the output directory the Swift harness created
    # It writes to Evaluation/<date>-generation-eval/data.json
    eval_dirs = sorted(
        [d for d in EVAL_DIR.iterdir() if d.is_dir() and "generation-eval" in d.name],
        key=lambda d: d.name, reverse=True
    )
    if not eval_dirs:
        print("ERROR: No generation-eval output directory found")
        sys.exit(1)

    latest_dir = eval_dirs[0]
    data_json = latest_dir / "data.json"
    scoring_csv = latest_dir / "scoring-template.csv"

    if not data_json.exists():
        print(f"ERROR: {data_json} not found")
        sys.exit(1)

    # Copy raw results to results/
    with open(data_json) as f:
        raw_data = json.load(f)

    raw_path = results_dir / "raw.json"
    with open(raw_path, "w") as f:
        json.dump(raw_data, f, indent=2, sort_keys=True)
    print(f"Wrote {raw_path}")

    # Copy scoring template
    if scoring_csv.exists():
        import shutil
        scoring_dest = results_dir / "scoring-template.csv"
        shutil.copy2(scoring_csv, scoring_dest)
        print(f"Wrote {scoring_dest}")

    # Write run metadata
    meta = {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "git_commit": git_sha(),
        "candidates_version": candidates_data["version"],
        "binary_path": str(binary),
        "elapsed_seconds": elapsed,
        "available_models": sorted(available),
        "candidates_fixture": candidates_data,
        "provenance": collect_provenance(
            corpus_fixtures={
                "generation_eval_prompts": CORPORA_DIR / "generation_eval_prompts_v1.json",
            },
            extra={"eval_binary_sha256": sha256_file(binary)},
        ),
    }
    meta_path = results_dir / "run_meta.json"
    with open(meta_path, "w") as f:
        json.dump(meta, f, indent=2, sort_keys=True)
    print(f"Wrote {meta_path}")

    print("\nDone. Run analyze_results.py next to generate summaries and plots.")


if __name__ == "__main__":
    main()