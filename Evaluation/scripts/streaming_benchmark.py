#!/usr/bin/env python3
"""
Streaming benchmark: download → smoke test → eval → archive → evict → leaderboard.

For each candidate in priority order:
  1. Skip if already benchmarked (checkpoint exists)
  2. Download model from HuggingFace (if not already on disk)
  3. Run MLXProbe smoke test
  4. Run GenerationEval with a temp single-candidate fixture
  5. Archive results to Evaluation/results/candidates/<name>/
  6. Update cumulative leaderboard
  7. Delete model directory + clean HF cache (if downloaded by this script)
  8. Continue to next candidate

At no point should more than one downloaded model remain on disk.
Models already present at start (e.g. qwen-0.5b, gemma-3n-e2b) are
benchmarked but NOT deleted.

Usage:
    python3 Evaluation/scripts/streaming_benchmark.py [--dry-run] [--keep-all]
           [--skip-existing] [--only NAME ...] [--early-stop]

Flags:
    --dry-run        Print what would happen without downloading or running
    --keep-all       Don't delete downloaded models after benchmarking
    --skip-existing  Skip candidates with existing checkpoints
    --only NAME      Only benchmark specific candidates (by name from fixture)
    --early-stop     Stop after finding a candidate that dominates the
                     current default (Pareto + score > 0.7)
    --hf-token TOKEN HuggingFace access token for gated models
"""
import argparse
import json
import math
import os
import shutil
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from provenance import collect_provenance, sha256_file

# The HF CDN silently drops idle connections; snapshot_download() has no
# default read timeout, so a dropped socket wedges the whole campaign in
# CLOSE_WAIT forever (observed 2026-07-14, two runs lost overnight).
os.environ.setdefault("HF_HUB_DOWNLOAD_TIMEOUT", "30")

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
EVAL_DIR = REPO_ROOT / "Evaluation"
MODELS_DIR = REPO_ROOT / "Models"
RESULTS_DIR = EVAL_DIR / "results"
CANDIDATES_DIR = RESULTS_DIR / "candidates"
CORPORA_DIR = EVAL_DIR / "corpora"
LEADERBOARD_PATH = RESULTS_DIR / "leaderboard.json"
LEADERBOARD_MD_PATH = RESULTS_DIR / "leaderboard.md"

# Priority ordering — front-loads models most likely to outperform
# the current default (Qwen2.5-0.5B). Centered on the 1-2B range.
PRIORITY_ORDER = [
    "qwen2.5-0.5b",      # baseline (already measured)
    "gemma-3n-e2b",      # baseline (already measured)
    "qwen2.5-1.5b",      # highest priority untested
    "gemma-3-1b",        # latency/quality sweet spot hypothesis
    "llama-3.2-1b",      # Meta edge optimization
    "smollm2-1.7b",      # HF edge model, Apache 2.0
    "qwen3-1.7b",        # improved Qwen instruction following
    "phi-4-mini",        # reported concise + strong instruction following
    "phi-3.5-mini",      # textbook-quality training
    "qwen2.5-3b",        # quality benchmark at 3B
    "llama-3.2-3b",      # Meta 3B
    "gemma-3n-e4b",      # quality ceiling reference
    "gemma-3-4b",        # standard Gemma at 4B
    "smollm2-360m",      # very fast, likely low quality
    "tinyllama-1.1b",    # older edge model
    "openelm-1.1b",      # Apple's own (non-commercial license)
    "openelm-3b",        # Apple's own (non-commercial license)
    "qwen3-4b",          # at the 4B limit
]

# Score weights (sum to 1.0)
SCORE_WEIGHTS = {
    "quality": 0.35,
    "latency": 0.30,
    "throughput": 0.15,
    "memory": 0.10,
    "stability": 0.05,
    "instruction_following": 0.05,
}

# Models that are already on disk at start and should NOT be deleted
PREExisting = {"Qwen2.5-0.5B-Instruct-4bit", "gemma-3n-E2B-it-lm-4bit"}


def load_candidates_fixture(explicit_path=None):
    """Load the candidates fixture — explicit path first, else newest version."""
    if explicit_path:
        path = Path(explicit_path)
        if not path.exists():
            raise FileNotFoundError(f"candidates fixture not found: {path}")
    else:
        for version in ("v3", "v2", "v1"):
            path = CORPORA_DIR / f"generation_eval_candidates_{version}.json"
            if path.exists():
                break
    with open(path) as f:
        fixture = json.load(f)
    fixture["_fixture_path"] = str(path)
    return fixture


def find_binary(product_name):
    """Find an executable binary — prefer Xcode build, then swift build."""
    candidates = [
        REPO_ROOT / ".build/xcode/Build/Products/Debug" / product_name,
        REPO_ROOT / ".build/xcode/Build/Products/Release" / product_name,
        REPO_ROOT / ".build/debug" / product_name,
        REPO_ROOT / ".build/release" / product_name,
    ]
    for p in candidates:
        if p.exists() and os.access(p, os.X_OK):
            return p
    return None


def candidate_checkpoint_dir(name):
    """Per-candidate checkpoint directory."""
    return CANDIDATES_DIR / name


def is_benchmarked(name):
    """Check if a candidate has a completed checkpoint."""
    d = candidate_checkpoint_dir(name)
    return (d / "raw.json").exists()


def download_model(repo_id, target_dir, hf_token=None):
    """Download a model from HuggingFace to target_dir."""
    try:
        from huggingface_hub import snapshot_download
    except ImportError:
        print("ERROR: huggingface_hub not installed. Run: pip install huggingface_hub")
        return False

    print(f"  Downloading {repo_id} → {target_dir}...")
    try:
        snapshot_download(
            repo_id=repo_id,
            local_dir=str(target_dir),
            local_dir_use_symlinks=False,
            token=hf_token,
        )
        print(f"  Download complete.")
        return True
    except Exception as e:
        print(f"  Download FAILED: {e}")
        return False


def clean_hf_cache(repo_id):
    """Clean HuggingFace cache for a specific repo only."""
    cache_root = Path.home() / ".cache" / "huggingface" / "hub"
    if not cache_root.exists():
        return

    # HF cache dirs are named models--<org>--<model-name>
    safe_name = repo_id.replace("/", "--")
    cache_pattern = f"models--{safe_name}"

    for d in cache_root.iterdir():
        if d.name.startswith(cache_pattern):
            print(f"  Cleaning HF cache: {d.name}")
            shutil.rmtree(d, ignore_errors=True)


def run_smoke_test(model_dir, mlxprobe_binary):
    """Run MLXProbe smoke test — load model + generate one token.

    If MLXProbe is a swift-build binary (not Xcode-built), it may crash
    on Metal kernel loading — same known limitation as GenerationEval.
    In that case, treat the smoke test as a pass and let GenerationEval
    be the real test (it has the same limitation anyway).
    """
    if mlxprobe_binary is None:
        print("  [skip] MLXProbe binary not found")
        return True

    # Check if this is an Xcode-built binary (can load Metal kernels)
    # vs a swift-build binary (will crash on metallib load)
    is_xcode_binary = ".build/xcode" in str(mlxprobe_binary)
    if not is_xcode_binary:
        print(f"  [skip] MLXProbe is swift-build (not Xcode) — smoke test would crash on Metal")
        return True

    print(f"  Smoke test: MLXProbe --json {model_dir} ...")
    try:
        proc = subprocess.run(
            [str(mlxprobe_binary), "--json", str(model_dir), "Say the word no"],
            capture_output=True, text=True, timeout=120, cwd=str(REPO_ROOT)
        )
        if proc.returncode != 0:
            print(f"  Smoke test FAILED (exit {proc.returncode})")
            if proc.stderr:
                print(f"  stderr: {proc.stderr[:500]}")
            return False
        # Verify we got valid JSON
        line = proc.stdout.strip().split("\n")[-1]
        result = json.loads(line)
        if "success" in result:
            print(f"  Smoke test OK: {result.get('success', {}).get('modelIdentifier', '?')}")
        return True
    except subprocess.TimeoutExpired:
        print(f"  Smoke test TIMEOUT (120s)")
        return False
    except Exception as e:
        print(f"  Smoke test ERROR: {e}")
        return False


def create_single_candidate_fixture(candidate, temp_path, version):
    """Create a temporary fixture with just one candidate.

    The version MUST be propagated from the parent fixture — GenerationEval
    stamps it into provenance.candidates_fixture_version, so hardcoding it
    would mislabel every checkpoint's provenance.
    """
    fixture = {
        "version": version,
        "candidates": [candidate],
    }
    with open(temp_path, "w") as f:
        json.dump(fixture, f, indent=2)
    return temp_path


def run_generation_eval(candidate, eval_binary, output_dir, temp_fixture):
    """Run GenerationEval for a single candidate."""
    cmd = [
        str(eval_binary),
        "--candidates", str(temp_fixture),
        "--output-dir", str(output_dir),
    ]
    print(f"  Running GenerationEval...")
    try:
        proc = subprocess.run(
            cmd, capture_output=True, text=True, timeout=600, cwd=str(REPO_ROOT)
        )
        # Write logs
        (output_dir / "stdout.log").write_text(proc.stdout)
        (output_dir / "stderr.log").write_text(proc.stderr)

        if proc.returncode != 0:
            print(f"  GenerationEval FAILED (exit {proc.returncode})")
            return False

        # Verify raw.json was written
        raw_path = output_dir / "data.json"
        if not raw_path.exists():
            print(f"  GenerationEval did not produce data.json")
            return False

        # Rename data.json → raw.json for consistency
        shutil.move(str(raw_path), str(output_dir / "raw.json"))

        # Copy scoring template
        scoring = output_dir / "scoring-template.csv"
        if scoring.exists():
            # Already in the right place
            pass

        print(f"  GenerationEval OK")
        return True
    except subprocess.TimeoutExpired:
        print(f"  GenerationEval TIMEOUT (600s)")
        return False
    except Exception as e:
        print(f"  GenerationEval ERROR: {e}")
        return False


def extract_metrics(raw_data):
    """Extract per-candidate metrics from raw.json for scoring."""
    candidates = raw_data.get("candidates", [])
    if not candidates:
        return None

    c = candidates[0]  # Single-candidate fixture
    if c.get("status") != "evaluated":
        return None

    prompts = c.get("prompts", [])
    if not prompts:
        return None

    n = len(prompts)
    generate_times = [p["generate_time"] for p in prompts]
    tps_values = [p["tokens_per_second"] for p in prompts]
    wcr_values = [p["word_count_ratio"] for p in prompts]
    cosine_values = [p["meaning_preservation_cosine"] for p in prompts
                     if p.get("meaning_preservation_cosine") is not None]

    # Failure metrics
    stop_reasons = [p.get("stop_reason", "unknown") for p in prompts]
    max_tok_rate = sum(1 for s in stop_reasons if s == "maxTokens") / n
    decoder_loops = sum(1 for p in prompts
                        if p.get("decoder_loop_period", 0) > 0
                        and p.get("decoder_loop_repeat_count", 1) > 2) / n
    echo_rate = sum(1 for p in prompts if p.get("prompt_echo_detected", False)) / n
    stability = 1.0 - (max_tok_rate + decoder_loops + echo_rate) / 3.0

    # Instruction following: proxy from instruction-following category
    instr_prompts = [p for p in prompts if p["category"] == "instruction-following"]
    # Count "good" responses: word_count_ratio < 2.0 for instruction-following
    instr_good = sum(1 for p in instr_prompts if p["word_count_ratio"] < 2.0)
    instr_following = instr_good / len(instr_prompts) if instr_prompts else 0.5

    return {
        "name": c["name"],
        "directory": c["directory"],
        "cold_load_time": c.get("cold_load_time"),
        "warm_load_time": c.get("warm_load_time"),
        "peak_rss_mb": c.get("peak_rss_mb"),
        "generate_time_mean": sum(generate_times) / n,
        "generate_time_std": (sum((g - sum(generate_times)/n)**2 for g in generate_times) / (n-1))**0.5 if n > 1 else 0,
        "tokens_per_second_mean": sum(tps_values) / n,
        "word_count_ratio_mean": sum(wcr_values) / n,
        "meaning_cosine_mean": sum(cosine_values) / len(cosine_values) if cosine_values else None,
        "meaning_cosine_n": len(cosine_values),
        "maxTokens_rate": max_tok_rate,
        "decoder_loop_rate": decoder_loops,
        "echo_rate": echo_rate,
        "stability": stability,
        "instruction_following": instr_following,
        "n_prompts": n,
    }


def normalize_metrics(all_metrics):
    """Min-max normalize each metric across all benchmarked candidates."""
    if len(all_metrics) < 2:
        return all_metrics

    # Collect ranges
    gt_vals = [m["generate_time_mean"] for m in all_metrics]
    tps_vals = [m["tokens_per_second_mean"] for m in all_metrics]
    rss_vals = [m["peak_rss_mb"] or 0 for m in all_metrics]
    wcr_vals = [m["word_count_ratio_mean"] for m in all_metrics]
    cos_vals = [m["meaning_cosine_mean"] for m in all_metrics if m["meaning_cosine_mean"] is not None]
    stab_vals = [m["stability"] for m in all_metrics]
    instr_vals = [m["instruction_following"] for m in all_metrics]

    def mm(val, lo, hi):
        if hi == lo:
            return 0.5
        return (val - lo) / (hi - lo)

    for m in all_metrics:
        # Latency: lower is better → invert
        m["norm_latency"] = 1.0 - mm(m["generate_time_mean"], min(gt_vals), max(gt_vals))
        # Throughput: higher is better
        m["norm_throughput"] = mm(m["tokens_per_second_mean"], min(tps_vals), max(tps_vals))
        # Memory: lower is better → invert
        m["norm_memory"] = 1.0 - mm(m["peak_rss_mb"] or 0, min(rss_vals), max(rss_vals))
        # Quality (cosine): higher is better
        if m["meaning_cosine_mean"] is not None and cos_vals:
            m["norm_quality"] = mm(m["meaning_cosine_mean"], min(cos_vals), max(cos_vals))
        else:
            m["norm_quality"] = 0.0
        # Stability: higher is better
        m["norm_stability"] = mm(m["stability"], min(stab_vals), max(stab_vals))
        # Instruction following: higher is better
        m["norm_instruction"] = mm(m["instruction_following"], min(instr_vals), max(instr_vals))

    return all_metrics


def compute_score(m):
    """Compute weighted overall score from normalized metrics."""
    return (
        SCORE_WEIGHTS["quality"] * m.get("norm_quality", 0)
        + SCORE_WEIGHTS["latency"] * m.get("norm_latency", 0)
        + SCORE_WEIGHTS["throughput"] * m.get("norm_throughput", 0)
        + SCORE_WEIGHTS["memory"] * m.get("norm_memory", 0)
        + SCORE_WEIGHTS["stability"] * m.get("norm_stability", 0)
        + SCORE_WEIGHTS["instruction_following"] * m.get("norm_instruction", 0)
    )


def compute_pareto(all_metrics):
    """Identify Pareto-optimal candidates (minimize latency, maximize quality)."""
    valid = [m for m in all_metrics if m["meaning_cosine_mean"] is not None]
    if len(valid) < 2:
        return [m["name"] for m in valid]

    pareto = []
    for m in valid:
        dominated = False
        for m2 in valid:
            if m["name"] == m2["name"]:
                continue
            if (m2["generate_time_mean"] <= m["generate_time_mean"]
                and m2["meaning_cosine_mean"] >= m["meaning_cosine_mean"]
                and (m2["generate_time_mean"] < m["generate_time_mean"]
                     or m2["meaning_cosine_mean"] > m["meaning_cosine_mean"])):
                dominated = True
                break
        if not dominated:
            pareto.append(m["name"])
    return pareto


def update_leaderboard(all_metrics):
    """Write cumulative leaderboard JSON + markdown."""
    # Normalize
    all_metrics = normalize_metrics(all_metrics)

    # Compute scores
    for m in all_metrics:
        m["overall_score"] = compute_score(m)

    # Sort by score descending
    all_metrics.sort(key=lambda m: -m["overall_score"])

    # Pareto
    pareto = compute_pareto(all_metrics)

    leaderboard = {
        "updated_at": datetime.now(timezone.utc).isoformat(),
        "n_candidates": len(all_metrics),
        "pareto_frontier": pareto,
        "weights": SCORE_WEIGHTS,
        "candidates": all_metrics,
    }

    LEADERBOARD_PATH.parent.mkdir(parents=True, exist_ok=True)
    with open(LEADERBOARD_PATH, "w") as f:
        json.dump(leaderboard, f, indent=2, default=str)
    print(f"  Leaderboard: {LEADERBOARD_PATH}")

    # Markdown
    md = generate_leaderboard_md(leaderboard)
    with open(LEADERBOARD_MD_PATH, "w") as f:
        f.write(md)
    print(f"  Leaderboard MD: {LEADERBOARD_MD_PATH}")

    return leaderboard


def generate_leaderboard_md(lb):
    lines = []
    lines.append("# NeuralCompose Generation Benchmark Leaderboard")
    lines.append("")
    lines.append(f"**Updated:** {lb['updated_at']}")
    lines.append(f"**Candidates evaluated:** {lb['n_candidates']}")
    lines.append(f"**Score weights:** quality={lb['weights']['quality']}, "
                 f"latency={lb['weights']['latency']}, "
                 f"throughput={lb['weights']['throughput']}, "
                 f"memory={lb['weights']['memory']}, "
                 f"stability={lb['weights']['stability']}, "
                 f"instruction_following={lb['weights']['instruction_following']}")
    lines.append("")

    pareto = lb.get("pareto_frontier", [])
    if pareto:
        lines.append("## Pareto Frontier")
        lines.append("")
        for p in pareto:
            lines.append(f"- **{p}**")
        lines.append("")

    lines.append("## Rankings")
    lines.append("")
    lines.append("| Rank | Candidate | Score | Latency (s) | tok/s | RSS (MB) | Cosine | Stability | Instr. Follow | Pareto |")
    lines.append("|------|-----------|-------|------------|-------|----------|--------|-----------|---------------|--------|")
    for i, m in enumerate(lb["candidates"]):
        is_pareto = "★" if m["name"] in pareto else ""
        cos = f"{m['meaning_cosine_mean']:.4f}" if m.get("meaning_cosine_mean") else "—"
        lines.append(
            f"| {i+1} | {m['name']} | {m['overall_score']:.3f} "
            f"| {m['generate_time_mean']:.2f} | {m['tokens_per_second_mean']:.1f} "
            f"| {m.get('peak_rss_mb', 0) or 0:.0f} | {cos} "
            f"| {m['stability']:.2f} | {m['instruction_following']:.2f} | {is_pareto} |"
        )
    lines.append("")

    lines.append("## Metric Definitions")
    lines.append("")
    lines.append("- **Score**: weighted sum of min-max normalized metrics across all evaluated candidates")
    lines.append("- **Latency**: mean generation time in seconds (lower is better)")
    lines.append("- **tok/s**: mean tokens per second (higher is better)")
    lines.append("- **RSS**: peak resident set size in MB (lower is better)")
    lines.append("- **Cosine**: mean meaning-preservation cosine similarity (higher is better, rewrite prompts only)")
    lines.append("- **Stability**: 1 - (maxTokens_rate + decoder_loop_rate + echo_rate) / 3")
    lines.append("- **Instr. Follow**: fraction of instruction-following prompts with word_count_ratio < 2.0")
    lines.append("- **Pareto**: ★ = not dominated on both latency and quality")
    lines.append("")

    return "\n".join(lines)


# Run-level context (fixture path, eval binary identity) captured once in
# main() and stamped into every candidate's metadata provenance. A campaign
# must use ONE binary throughout — mixing harness builds makes checkpoints
# incomparable, so the binary hash is part of the evidence.
RUN_CONTEXT = {}


def write_metadata(name, candidate, model_dir, downloaded, smoke_ok, eval_ok, elapsed, error=None):
    """Write per-candidate metadata."""
    d = candidate_checkpoint_dir(name)
    d.mkdir(parents=True, exist_ok=True)
    meta = {
        "name": name,
        "candidate": candidate,
        "model_dir": str(model_dir),
        "downloaded": downloaded,
        "smoke_test_passed": smoke_ok,
        "eval_completed": eval_ok,
        "elapsed_seconds": elapsed,
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "error": error,
        "provenance": collect_provenance(
            corpus_fixtures={
                "generation_eval_candidates": RUN_CONTEXT.get("fixture_path"),
                "generation_eval_prompts": CORPORA_DIR / "generation_eval_prompts_v1.json",
            } if RUN_CONTEXT.get("fixture_path") else None,
            extra={
                "eval_binary_path": RUN_CONTEXT.get("binary_path"),
                "eval_binary_sha256": RUN_CONTEXT.get("binary_sha256"),
            },
        ),
    }
    with open(d / "metadata.json", "w") as f:
        json.dump(meta, f, indent=2, default=str)


def should_early_stop(leaderboard, current_default="qwen2.5-0.5b"):
    """Check if a candidate clearly dominates the current default."""
    candidates = leaderboard.get("candidates", [])
    if len(candidates) < 3:
        return False

    pareto = leaderboard.get("pareto_frontier", [])
    # Find the top candidate
    top = candidates[0] if candidates else None
    if not top:
        return False

    # Stop if top candidate is Pareto-optimal AND score > 0.7
    # AND it's not the current default
    if (top["name"] in pareto
        and top["overall_score"] > 0.7
        and top["name"] != current_default):
        return True
    return False


def main():
    parser = argparse.ArgumentParser(description="Streaming benchmark: download → eval → evict → leaderboard")
    parser.add_argument("--dry-run", action="store_true",
                        help="Print what would happen without executing")
    parser.add_argument("--keep-all", action="store_true",
                        help="Don't delete downloaded models after benchmarking")
    parser.add_argument("--skip-existing", action="store_true",
                        help="Skip candidates with existing checkpoints")
    parser.add_argument("--only", action="append", default=[],
                        help="Only benchmark specific candidate names")
    parser.add_argument("--early-stop", action="store_true",
                        help="Stop early if a candidate dominates the current default")
    parser.add_argument("--hf-token", default=None,
                        help="HuggingFace access token for gated models")
    parser.add_argument("--candidates", default=None,
                        help="Path to candidates fixture (default: newest "
                             "generation_eval_candidates_vN.json)")
    args = parser.parse_args()

    CANDIDATES_DIR.mkdir(parents=True, exist_ok=True)

    # Load token from .env if not provided (gated repos, e.g. gemma)
    if not args.hf_token:
        env_path = REPO_ROOT / ".env"
        if env_path.exists():
            with open(env_path) as f:
                for line in f:
                    line = line.strip()
                    if line.startswith("HF_API_TOKEN="):
                        args.hf_token = line.split("=", 1)[1].strip().strip('"').strip("'")
                        print("HF token loaded from .env (not displayed)")
                        break

    # Load fixture
    fixture = load_candidates_fixture(args.candidates)
    fixture_version = fixture.get("version")
    print(f"Candidates fixture: {fixture['_fixture_path']} (version {fixture_version})")
    candidates_by_name = {c["name"]: c for c in fixture["candidates"]}

    # Determine order
    if args.only:
        order = [n for n in args.only if n in candidates_by_name]
    else:
        order = [n for n in PRIORITY_ORDER if n in candidates_by_name]
        # Add any candidates not in the priority list
        for c in fixture["candidates"]:
            if c["name"] not in order:
                order.append(c["name"])

    print("=== NeuralCompose Streaming Benchmark ===")
    print(f"Candidates in priority order: {order}")
    print(f"Dry run: {args.dry_run}")
    print(f"Keep all models: {args.keep_all}")
    print(f"Early stop: {args.early_stop}")
    print()

    # Find binaries
    eval_binary = find_binary("GenerationEval")
    mlxprobe_binary = find_binary("MLXProbe")

    if not eval_binary:
        print("ERROR: GenerationEval binary not found.")
        print("Build it first: swift build --product GenerationEval")
        if not args.dry_run:
            sys.exit(1)
    else:
        print(f"GenerationEval: {eval_binary}")
        RUN_CONTEXT["fixture_path"] = fixture["_fixture_path"]
        RUN_CONTEXT["binary_path"] = str(eval_binary)
        RUN_CONTEXT["binary_sha256"] = sha256_file(eval_binary)
        print(f"GenerationEval sha256: {RUN_CONTEXT['binary_sha256'][:16]}…")
    if mlxprobe_binary:
        print(f"MLXProbe: {mlxprobe_binary}")
    else:
        print("MLXProbe: not found (smoke tests will be skipped)")
    print()

    # Load existing leaderboard
    all_metrics = []
    if LEADERBOARD_PATH.exists():
        with open(LEADERBOARD_PATH) as f:
            lb = json.load(f)
            all_metrics = lb.get("candidates", [])
            print(f"Loaded existing leaderboard: {len(all_metrics)} candidates")

    # Process each candidate
    for name in order:
        candidate = candidates_by_name[name]
        model_dir_name = candidate["directory"]
        model_dir = MODELS_DIR / model_dir_name
        checkpoint_dir = candidate_checkpoint_dir(name)

        print(f"\n{'='*60}")
        print(f"Candidate: {name}")
        print(f"Directory: {model_dir_name}")
        print(f"{'='*60}")

        # Candidates marked unavailable in the fixture (no usable HF repo
        # exists) are recorded, not silently dropped.
        if candidate.get("unavailable"):
            reason = candidate.get("unavailable_reason", "no usable HF repo")
            print(f"  SKIP — unavailable: {reason}")
            if not args.dry_run:
                write_metadata(name, candidate, model_dir, False, False, False, 0,
                               error=f"unavailable: {reason}")
            continue

        # Skip if already benchmarked
        if args.skip_existing and is_benchmarked(name):
            print(f"  SKIP — checkpoint exists at {checkpoint_dir}")
            # Load existing metrics
            raw_path = checkpoint_dir / "raw.json"
            if raw_path.exists():
                with open(raw_path) as f:
                    raw = json.load(f)
                m = extract_metrics(raw)
                if m and not any(am["name"] == name for am in all_metrics):
                    all_metrics.append(m)
            continue

        # Check if model is on disk
        was_on_disk = model_dir.exists()
        downloaded = False

        if not was_on_disk:
            if args.dry_run:
                print(f"  [DRY RUN] Would download mlx-community/{model_dir_name}")
                print(f"  [DRY RUN] Would smoke test, eval, archive, and delete")
                continue

            # Download
            repo_id = f"mlx-community/{model_dir_name}"
            checkpoint_dir.mkdir(parents=True, exist_ok=True)
            success = download_model(repo_id, model_dir, args.hf_token)
            if not success:
                write_metadata(name, candidate, model_dir, False, False, False, 0,
                             error="download_failed")
                print(f"  SKIPPED — download failed")
                continue
            downloaded = True
        else:
            print(f"  Model already on disk: {model_dir}")
            checkpoint_dir.mkdir(parents=True, exist_ok=True)

        if args.dry_run:
            print(f"  [DRY RUN] Would smoke test + eval + archive")
            continue

        start_time = time.time()

        # Smoke test
        smoke_ok = run_smoke_test(model_dir, mlxprobe_binary)
        if not smoke_ok:
            write_metadata(name, candidate, model_dir, downloaded, False, False,
                         time.time() - start_time, error="smoke_test_failed")
            print(f"  SKIPPED — smoke test failed")
            if downloaded and not args.keep_all:
                print(f"  Deleting model: {model_dir}")
                shutil.rmtree(model_dir, ignore_errors=True)
                clean_hf_cache(f"mlx-community/{model_dir_name}")
            continue

        # Run GenerationEval
        temp_fixture = checkpoint_dir / "_candidate.json"
        create_single_candidate_fixture(candidate, temp_fixture, fixture_version)
        eval_ok = run_generation_eval(candidate, eval_binary, checkpoint_dir, temp_fixture)
        temp_fixture.unlink(missing_ok=True)

        elapsed = time.time() - start_time

        if eval_ok:
            # Extract metrics
            raw_path = checkpoint_dir / "raw.json"
            with open(raw_path) as f:
                raw = json.load(f)
            metrics = extract_metrics(raw)
            if metrics:
                # Update or add to all_metrics
                all_metrics = [m for m in all_metrics if m["name"] != name]
                all_metrics.append(metrics)

                # Update leaderboard
                leaderboard = update_leaderboard(all_metrics)

                # Print current ranking
                print(f"\n  Current Leaderboard:")
                sorted_metrics = sorted(all_metrics,
                                       key=lambda m: -compute_score(m))
                for i, m in enumerate(sorted_metrics[:5]):
                    marker = " ←" if m["name"] == name else ""
                    score = compute_score(m)
                    # Recompute with normalization
                    normed = normalize_metrics([m for m in all_metrics])
                    for nm in normed:
                        nm["overall_score"] = compute_score(nm)
                    sorted_normed = sorted(normed, key=lambda m: -m["overall_score"])
                    score = next(nm["overall_score"] for nm in sorted_normed if nm["name"] == m["name"])
                    print(f"    {i+1}. {m['name']:25s} score={score:.3f} "
                          f"lat={m['generate_time_mean']:.2f}s "
                          f"tok/s={m['tokens_per_second_mean']:.1f}"
                          f"{marker}")

                # Early stopping
                if args.early_stop:
                    # Recompute leaderboard with scores
                    normed = normalize_metrics([m for m in all_metrics])
                    for nm in normed:
                        nm["overall_score"] = compute_score(nm)
                    normed.sort(key=lambda m: -m["overall_score"])
                    lb_for_stop = {
                        "candidates": normed,
                        "pareto_frontier": compute_pareto(normed),
                    }
                    if should_early_stop(lb_for_stop):
                        print(f"\n  *** EARLY STOP: {normed[0]['name']} dominates "
                              f"(score={normed[0]['overall_score']:.3f}) ***")
                        write_metadata(name, candidate, model_dir, downloaded,
                                     smoke_ok, eval_ok, elapsed)
                        # Don't delete this model if it's the winner
                        break
        else:
            print(f"  GenerationEval failed — archiving logs only")

        write_metadata(name, candidate, model_dir, downloaded, smoke_ok, eval_ok, elapsed)

        # Evict model
        if downloaded and not args.keep_all:
            print(f"  Deleting model: {model_dir}")
            shutil.rmtree(model_dir, ignore_errors=True)
            clean_hf_cache(f"mlx-community/{model_dir_name}")
            print(f"  Model evicted. Disk freed.")
        elif was_on_disk:
            print(f"  Model was pre-existing — NOT deleting.")

    # Final leaderboard
    if all_metrics:
        print(f"\n{'='*60}")
        print("FINAL LEADERBOARD")
        print(f"{'='*60}")
        update_leaderboard(all_metrics)

        # Identify top 3 to keep
        normed = normalize_metrics([m for m in all_metrics])
        for nm in normed:
            nm["overall_score"] = compute_score(nm)
        normed.sort(key=lambda m: -m["overall_score"])
        top3 = [m["name"] for m in normed[:3]]
        print(f"\nTop 3 candidates to keep on disk:")
        for n in top3:
            print(f"  - {n}")
        print(f"\nTo use these models, re-download them with:")
        print(f"  huggingface-cli download mlx-community/<directory> --local-dir Models/<directory>")


if __name__ == "__main__":
    main()