#!/usr/bin/env python3
"""
Streaming embedding benchmark: download → benchmark → archive → evict → leaderboard.

Mirrors the generation eval's streaming_benchmark.py but for embedding models.

For each candidate in priority order:
  1. Skip if already benchmarked (checkpoint exists)
  2. Download model from HuggingFace (if not already on disk)
  3. Classify runtime compatibility
  4. Run embedding_benchmark.py for each supported runtime
  5. Archive results to Evaluation/results/embeddings/<model_name>/
  6. Update cumulative leaderboard
  7. Delete model directory + clean HF cache (if downloaded by this script)
  8. Continue to next candidate

At no point should more than one downloaded model remain on disk.

Usage:
    python3 Evaluation/scripts/embedding_streaming_benchmark.py [--dry-run] [--keep-all]
           [--skip-existing] [--only NAME ...] [--early-stop]
"""
import argparse
import gc
import json
import math
import os
import shutil
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

import numpy as np

from provenance import collect_provenance

# The HF CDN silently drops idle connections; snapshot_download() has no
# default read timeout, so a dropped socket wedges the whole campaign in
# CLOSE_WAIT forever (observed 2026-07-14, two runs lost overnight).
os.environ.setdefault("HF_HUB_DOWNLOAD_TIMEOUT", "30")

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
EVAL_DIR = REPO_ROOT / "Evaluation"
RESULTS_DIR = EVAL_DIR / "results" / "embeddings"
MODELS_DIR = REPO_ROOT / "Models"
CORPORA_DIR = EVAL_DIR / "corpora"
LEADERBOARD_PATH = RESULTS_DIR / "leaderboard.json"
LEADERBOARD_MD_PATH = RESULTS_DIR / "leaderboard.md"
SUMMARY_JSON_PATH = RESULTS_DIR / "summary.json"
SUMMARY_CSV_PATH = RESULTS_DIR / "summary.csv"
SUMMARY_MD_PATH = RESULTS_DIR / "summary.md"
COMPATIBILITY_PATH = RESULTS_DIR / "compatibility_matrix.json"

# Score weights (sum to 1.0)
# Neighborhood stability is elevated to a headline metric because retrieval
# pipelines care more about preserving neighborhood structure than cosine
# magnitude alone.
SCORE_WEIGHTS = {
    "quality": 0.25,       # paraphrase + antonym separation + retrieval
    "stability": 0.20,     # ASR/typo/hesitation noise robustness
    "neighborhood": 0.15,  # neighborhood stability under perturbation (Jaccard)
    "semantic": 0.10,      # semantic-preserving transform robustness
    "latency": 0.15,       # cold load + warm encode
    "throughput": 0.05,    # embeddings per second
    "memory": 0.05,        # peak RSS
    "consistency": 0.05,   # NN determinism
}


def load_candidates_fixture():
    path = CORPORA_DIR / "embedding_bench_candidates_v1.json"
    with open(path) as f:
        return json.load(f)


def load_compat_matrix():
    if COMPATIBILITY_PATH.exists():
        with open(COMPATIBILITY_PATH) as f:
            return json.load(f)
    return None


def candidate_checkpoint_dir(name, runtime="python"):
    """Per-candidate checkpoint directory, separated by runtime."""
    return RESULTS_DIR / name / runtime


def is_benchmarked(name, runtime="python"):
    d = candidate_checkpoint_dir(name, runtime)
    return (d / "benchmark.json").exists()


def archive_failed_checkpoint(name, runtime):
    """If the checkpoint recorded a failure, rename it aside so the candidate
    is retried. The failed artifact is preserved (never deleted) — a failure
    is evidence, and --retry-failed only makes sense after the environment
    cause (missing package, network) has been fixed."""
    bench_path = candidate_checkpoint_dir(name, runtime) / "benchmark.json"
    if not bench_path.exists():
        return False
    try:
        with open(bench_path) as f:
            status = json.load(f).get("status", "")
    except Exception:
        return False
    if not str(status).startswith("failed"):
        return False
    ts = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    archived = bench_path.with_name(f"benchmark.failed-{ts}.json")
    bench_path.rename(archived)
    print(f"  [{runtime}] archived failed checkpoint → {archived.name}")
    return True


def download_model(repo_id, target_dir, hf_token=None):
    """Download a model from HuggingFace to target_dir."""
    try:
        from huggingface_hub import snapshot_download
    except ImportError:
        print("ERROR: huggingface_hub not installed")
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
    safe_name = repo_id.replace("/", "--")
    cache_pattern = f"models--{safe_name}"
    for d in cache_root.iterdir():
        if d.name.startswith(cache_pattern):
            print(f"  Cleaning HF cache: {d.name}")
            shutil.rmtree(d, ignore_errors=True)


def run_benchmark_subprocess(repo_id, model_name, model_path, output_dir, runtime, hf_token):
    """Run embedding_benchmark.py as a subprocess."""
    cmd = [
        sys.executable,
        str(Path(__file__).parent / "embedding_benchmark.py"),
        "--repo-id", repo_id,
        "--model-name", model_name,
        "--model-path", str(model_path),
        "--output-dir", str(output_dir),
        "--runtime", runtime,
    ]
    if hf_token:
        cmd.extend(["--hf-token", hf_token])

    print(f"  Running benchmark ({runtime})...")
    try:
        proc = subprocess.run(
            cmd, capture_output=True, text=True, timeout=600, cwd=str(REPO_ROOT)
        )
        (output_dir / "stdout.log").write_text(proc.stdout)
        (output_dir / "stderr.log").write_text(proc.stderr)

        if proc.returncode != 0:
            print(f"  Benchmark FAILED (exit {proc.returncode})")
            if proc.stderr:
                print(f"  stderr (last 500): {proc.stderr[-500:]}")
            return False
        return True
    except subprocess.TimeoutExpired:
        print(f"  Benchmark TIMEOUT (600s)")
        return False
    except Exception as e:
        print(f"  Benchmark ERROR: {e}")
        return False


def extract_metrics(benchmark_data):
    """Extract per-model metrics from benchmark.json for scoring."""
    if benchmark_data.get("status") != "evaluated":
        return None

    stability = benchmark_data.get("stability", {})
    stability_overall = stability.get("overall", {})
    semantic_overall = stability.get("semantic_overall", {})
    neighborhood = benchmark_data.get("neighborhood_stability", {})
    neighborhood_noise = neighborhood.get("noise_overall", {})
    neighborhood_semantic = neighborhood.get("semantic_overall", {})

    paraphrase = benchmark_data.get("paraphrase_pairs", {})
    antonym = benchmark_data.get("antonym_pairs", {})
    command_groups = benchmark_data.get("command_groups", {})
    retrieval = benchmark_data.get("retrieval", {})
    nn_cons = benchmark_data.get("nn_consistency", {})

    # Quality score: paraphrase mean (high) + separation ratio (high) + retrieval (high) - antonym mean (low = better)
    paraphrase_mean = paraphrase.get("mean", 0)
    separation_ratio = command_groups.get("separation_ratio", 0)
    retrieval_top1 = retrieval.get("mean_top1_similarity", 0)
    antonym_mean = antonym.get("mean", 0)

    # Normalize separation ratio to [0, 1] range — typical values 1.5-5
    separation_norm = min(separation_ratio / 5.0, 1.0)

    # Quality composite: paraphrase + retrieval + separation - antonym
    quality = (paraphrase_mean * 0.3 + retrieval_top1 * 0.3 +
               separation_norm * 0.3 + (1.0 - antonym_mean) * 0.1)

    return {
        "name": benchmark_data["model_name"],
        "runtime": benchmark_data["runtime"],
        "repo_id": benchmark_data["repo_id"],
        "dimension": benchmark_data.get("dimension"),
        "model_size_mb": benchmark_data.get("model_size_mb", 0),
        "cold_load_time": benchmark_data.get("cold_load_time", 0),
        "warm_encode_ms": benchmark_data.get("warm_encode_time_ms", 0),
        "embeddings_per_second": benchmark_data.get("embeddings_per_second", 0),
        "peak_rss_mb": benchmark_data.get("peak_rss_mb", 0),
        "stability_mean": stability_overall.get("mean", 0),
        "stability_median": stability_overall.get("median", 0),
        "stability_std": stability_overall.get("std", 0),
        "stability_ci_95_lo": stability_overall.get("ci_95_lo", 0),
        "stability_ci_95_hi": stability_overall.get("ci_95_hi", 0),
        "stability_n": stability_overall.get("n", 0),
        "semantic_stability_mean": semantic_overall.get("mean", 0),
        "semantic_stability_std": semantic_overall.get("std", 0),
        "semantic_stability_n": semantic_overall.get("n", 0),
        "neighborhood_stability_mean": neighborhood_noise.get("mean", 0),
        "neighborhood_stability_std": neighborhood_noise.get("std", 0),
        "neighborhood_semantic_mean": neighborhood_semantic.get("mean", 0),
        "neighborhood_semantic_std": neighborhood_semantic.get("std", 0),
        "paraphrase_mean": paraphrase_mean,
        "antonym_mean": antonym_mean,
        "separation_ratio": separation_ratio,
        "retrieval_top1": retrieval_top1,
        "retrieval_top5": retrieval.get("mean_top5_similarity", 0),
        "nn_consistency": nn_cons.get("mean_consistency", 0),
        "quality_score": quality,
        "failure_rate": benchmark_data.get("failure_rate", 0),
        "failure_class": benchmark_data.get("failure_class"),
        "failure_reason": benchmark_data.get("failure_reason"),
    }


def extract_stability_by_type(benchmark_data):
    """Extract per-variant-type stability for reporting."""
    stability = benchmark_data.get("stability", {})
    per_type = stability.get("per_variant_type", {})
    return {
        vtype: {
            "mean": v.get("mean", 0),
            "median": v.get("median", 0),
            "std": v.get("std", 0),
        }
        for vtype, v in per_type.items()
    }


def normalize_metrics(all_metrics):
    """Min-max normalize each metric across all benchmarked candidates."""
    if len(all_metrics) < 2:
        return all_metrics

    def get_range(key):
        vals = [m.get(key, 0) for m in all_metrics if m.get(key) is not None]
        if not vals:
            return 0, 1
        return min(vals), max(vals)

    def mm(val, lo, hi):
        if hi == lo:
            return 0.5
        return (val - lo) / (hi - lo)

    ranges = {
        "cold_load_time": get_range("cold_load_time"),
        "warm_encode_ms": get_range("warm_encode_ms"),
        "embeddings_per_second": get_range("embeddings_per_second"),
        "peak_rss_mb": get_range("peak_rss_mb"),
        "stability_mean": get_range("stability_mean"),
        "semantic_stability_mean": get_range("semantic_stability_mean"),
        "neighborhood_stability_mean": get_range("neighborhood_stability_mean"),
        "quality_score": get_range("quality_score"),
        "nn_consistency": get_range("nn_consistency"),
    }

    for m in all_metrics:
        # Latency: lower is better → invert
        m["norm_latency"] = 1.0 - mm(m.get("cold_load_time", 0), *ranges["cold_load_time"])
        m["norm_warm_latency"] = 1.0 - mm(m.get("warm_encode_ms", 0), *ranges["warm_encode_ms"])
        # Throughput: higher is better
        m["norm_throughput"] = mm(m.get("embeddings_per_second", 0), *ranges["embeddings_per_second"])
        # Memory: lower is better → invert
        m["norm_memory"] = 1.0 - mm(m.get("peak_rss_mb", 0), *ranges["peak_rss_mb"])
        # Noise stability: higher is better
        m["norm_stability"] = mm(m.get("stability_mean", 0), *ranges["stability_mean"])
        # Semantic stability: higher is better
        m["norm_semantic"] = mm(m.get("semantic_stability_mean", 0), *ranges["semantic_stability_mean"])
        # Neighborhood stability: higher is better
        m["norm_neighborhood"] = mm(m.get("neighborhood_stability_mean", 0), *ranges["neighborhood_stability_mean"])
        # Quality: higher is better
        m["norm_quality"] = mm(m.get("quality_score", 0), *ranges["quality_score"])
        # Consistency: higher is better
        m["norm_consistency"] = mm(m.get("nn_consistency", 0), *ranges["nn_consistency"])

    return all_metrics


def compute_score(m):
    """Compute weighted overall score from normalized metrics."""
    return (
        SCORE_WEIGHTS["quality"] * m.get("norm_quality", 0)
        + SCORE_WEIGHTS["stability"] * m.get("norm_stability", 0)
        + SCORE_WEIGHTS["neighborhood"] * m.get("norm_neighborhood", 0)
        + SCORE_WEIGHTS["semantic"] * m.get("norm_semantic", 0)
        + SCORE_WEIGHTS["latency"] * m.get("norm_latency", 0)
        + SCORE_WEIGHTS["throughput"] * m.get("norm_throughput", 0)
        + SCORE_WEIGHTS["memory"] * m.get("norm_memory", 0)
        + SCORE_WEIGHTS["consistency"] * m.get("norm_consistency", 0)
    )


def compute_pareto(all_metrics):
    """Identify Pareto-optimal candidates (minimize latency, maximize quality, maximize stability)."""
    valid = [m for m in all_metrics if m.get("quality_score") is not None and m.get("failure_rate", 0) < 1]
    if len(valid) < 2:
        return [m["name"] for m in valid]

    pareto = []
    for m in valid:
        dominated = False
        for m2 in valid:
            if m["name"] == m2["name"] and m["runtime"] == m2["runtime"]:
                continue
            # m2 dominates m if m2 is >= on all objectives and > on at least one
            if (m2.get("quality_score", 0) >= m.get("quality_score", 0)
                and m2.get("stability_mean", 0) >= m.get("stability_mean", 0)
                and m2.get("cold_load_time", float('inf')) <= m.get("cold_load_time", float('inf'))
                and (m2.get("quality_score", 0) > m.get("quality_score", 0)
                     or m2.get("stability_mean", 0) > m.get("stability_mean", 0)
                     or m2.get("cold_load_time", float('inf')) < m.get("cold_load_time", float('inf')))):
                dominated = True
                break
        if not dominated:
            pareto.append(f"{m['name']} ({m['runtime']})")
    return pareto


def update_leaderboard(all_metrics):
    """Write cumulative leaderboard JSON + markdown + summary files."""
    RESULTS_DIR.mkdir(parents=True, exist_ok=True)

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

    with open(LEADERBOARD_PATH, "w") as f:
        json.dump(leaderboard, f, indent=2, default=str)
    print(f"  Leaderboard: {LEADERBOARD_PATH}")

    # Markdown leaderboard
    md = generate_leaderboard_md(leaderboard)
    with open(LEADERBOARD_MD_PATH, "w") as f:
        f.write(md)
    print(f"  Leaderboard MD: {LEADERBOARD_MD_PATH}")

    # Summary CSV
    csv_lines = ["name,runtime,dimension,model_size_mb,cold_load_time,warm_encode_ms,"
                 "embeddings_per_second,peak_rss_mb,stability_mean,stability_std,"
                 "paraphrase_mean,antonym_mean,separation_ratio,retrieval_top1,"
                 "nn_consistency,quality_score,overall_score,failure_rate"]
    for m in all_metrics:
        csv_lines.append(
            f"{m['name']},{m['runtime']},{m.get('dimension','')},"
            f"{m.get('model_size_mb',0):.1f},{m.get('cold_load_time',0):.2f},"
            f"{m.get('warm_encode_ms',0):.1f},{m.get('embeddings_per_second',0):.0f},"
            f"{m.get('peak_rss_mb',0):.0f},{m.get('stability_mean',0):.4f},"
            f"{m.get('stability_std',0):.4f},{m.get('paraphrase_mean',0):.4f},"
            f"{m.get('antonym_mean',0):.4f},{m.get('separation_ratio',0):.2f},"
            f"{m.get('retrieval_top1',0):.4f},{m.get('nn_consistency',0):.4f},"
            f"{m.get('quality_score',0):.4f},{m.get('overall_score',0):.4f},"
            f"{m.get('failure_rate',0):.2f}"
        )
    with open(SUMMARY_CSV_PATH, "w") as f:
        f.write("\n".join(csv_lines) + "\n")
    print(f"  Summary CSV: {SUMMARY_CSV_PATH}")

    # Summary JSON
    summary = {
        "updated_at": leaderboard["updated_at"],
        "n_candidates": len(all_metrics),
        "pareto_frontier": pareto,
        "weights": SCORE_WEIGHTS,
        "top_5": all_metrics[:5],
        "all_candidates": all_metrics,
    }
    with open(SUMMARY_JSON_PATH, "w") as f:
        json.dump(summary, f, indent=2, default=str)
    print(f"  Summary JSON: {SUMMARY_JSON_PATH}")

    return leaderboard


def generate_leaderboard_md(lb):
    lines = []
    lines.append("# NeuralCompose Embedding Benchmark Leaderboard")
    lines.append("")
    lines.append(f"**Updated:** {lb['updated_at']}")
    lines.append(f"**Candidates evaluated:** {lb['n_candidates']}")
    lines.append(f"**Score weights:** quality={lb['weights']['quality']}, "
                 f"stability={lb['weights']['stability']}, "
                 f"latency={lb['weights']['latency']}, "
                 f"throughput={lb['weights']['throughput']}, "
                 f"memory={lb['weights']['memory']}, "
                 f"consistency={lb['weights']['consistency']}")
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
    lines.append("| Rank | Model | Runtime | Score | Stability | Quality | Latency (s) | emb/s | RSS (MB) | Dim | Size (MB) | Pareto |")
    lines.append("|------|-------|---------|-------|-----------|---------|-------------|-------|----------|-----|-----------|--------|")
    for i, m in enumerate(lb["candidates"]):
        is_pareto = "★" if f"{m['name']} ({m['runtime']})" in pareto else ""
        lines.append(
            f"| {i+1} | {m['name']} | {m['runtime']} | {m['overall_score']:.3f} "
            f"| {m.get('stability_mean', 0):.4f} | {m.get('quality_score', 0):.4f} "
            f"| {m.get('cold_load_time', 0):.2f} | {m.get('embeddings_per_second', 0):.0f} "
            f"| {m.get('peak_rss_mb', 0):.0f} | {m.get('dimension', '?')} "
            f"| {m.get('model_size_mb', 0):.0f} | {is_pareto} |"
        )
    lines.append("")

    lines.append("## Metric Definitions")
    lines.append("")
    lines.append("- **Score**: weighted sum of min-max normalized metrics across all evaluated candidates")
    lines.append("- **Stability**: mean cosine similarity between original and ASR/typo/hesitation/filler/punctuation/capitalization variants")
    lines.append("- **Quality**: composite of paraphrase similarity, retrieval accuracy, command-group separation, antonym discrimination")
    lines.append("- **Latency**: cold load time in seconds (lower is better)")
    lines.append("- **emb/s**: embeddings per second at batch size 128 (higher is better)")
    lines.append("- **RSS**: peak resident set size in MB (lower is better)")
    lines.append("- **Dim**: embedding dimensionality")
    lines.append("- **Size**: model size on disk in MB")
    lines.append("- **Pareto**: ★ = not dominated on quality, stability, and latency")
    lines.append("")

    # Per-variant-type stability breakdown
    lines.append("## Stability by Variant Type")
    lines.append("")
    lines.append("| Model | Runtime | ASR | Typo | Hesitation | Filler | Punctuation | Capitalization | No-Punct | Doubled |")
    lines.append("|-------|---------|-----|------|------------|--------|-------------|----------------|----------|---------|")
    for m in lb["candidates"]:
        st = m.get("stability_by_type", {})
        lines.append(
            f"| {m['name']} | {m['runtime']} "
            f"| {st.get('asr', {}).get('mean', 0):.4f} "
            f"| {st.get('typo', {}).get('mean', 0):.4f} "
            f"| {st.get('hesitation', {}).get('mean', 0):.4f} "
            f"| {st.get('filler', {}).get('mean', 0):.4f} "
            f"| {st.get('punctuation', {}).get('mean', 0):.4f} "
            f"| {st.get('capitalization', {}).get('mean', 0):.4f} "
            f"| {st.get('no_punctuation', {}).get('mean', 0):.4f} "
            f"| {st.get('doubled_word', {}).get('mean', 0):.4f} |"
        )
    lines.append("")

    return "\n".join(lines)


def write_metadata(name, candidate, model_dir, downloaded, eval_ok, elapsed,
                   runtimes_tested, error=None):
    """Write per-candidate metadata."""
    d = RESULTS_DIR / name
    d.mkdir(parents=True, exist_ok=True)
    meta = {
        "name": name,
        "candidate": candidate,
        "model_dir": str(model_dir),
        "downloaded": downloaded,
        "eval_completed": eval_ok,
        "runtimes_tested": runtimes_tested,
        "elapsed_seconds": elapsed,
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "error": error,
        "provenance": collect_provenance(
            corpus_fixtures={
                "embedding_bench_candidates": CORPORA_DIR / "embedding_bench_candidates_v1.json",
                "embedding_bench_corpus": CORPORA_DIR / "embedding_bench_corpus_v1.json",
            }
        ),
    }
    with open(d / "metadata.json", "w") as f:
        json.dump(meta, f, indent=2, default=str)


def main():
    parser = argparse.ArgumentParser(description="Streaming embedding benchmark")
    parser.add_argument("--dry-run", action="store_true")
    parser.add_argument("--keep-all", action="store_true")
    parser.add_argument("--skip-existing", action="store_true")
    parser.add_argument("--only", action="append", default=[])
    parser.add_argument("--early-stop", action="store_true")
    parser.add_argument("--hf-token", default=None)
    parser.add_argument("--retry-failed", action="store_true",
                        help="Re-run candidates whose checkpoint recorded a "
                             "failure; the failed benchmark.json is renamed "
                             "aside (preserved), never deleted")
    args = parser.parse_args()

    RESULTS_DIR.mkdir(parents=True, exist_ok=True)

    # Load token
    hf_token = args.hf_token
    if not hf_token:
        env_path = REPO_ROOT / ".env"
        if env_path.exists():
            with open(env_path) as f:
                for line in f:
                    line = line.strip()
                    if line.startswith("HF_API_TOKEN="):
                        hf_token = line.split("=", 1)[1].strip().strip('"').strip("'")
                        break

    if hf_token:
        print("HF token loaded (not displayed)")

    # Load fixture
    fixture = load_candidates_fixture()
    candidates_by_name = {c["name"]: c for c in fixture["candidates"]}

    # Load compatibility matrix
    compat = load_compat_matrix()
    compat_by_name = {}
    if compat:
        for c in compat.get("candidates", []):
            compat_by_name[c["name"]] = c

    # Determine order (by priority)
    if args.only:
        order = [n for n in args.only if n in candidates_by_name]
    else:
        order = sorted(candidates_by_name.keys(),
                       key=lambda n: candidates_by_name[n].get("priority", 99))

    print(f"\n=== NeuralCompose Streaming Embedding Benchmark ===")
    print(f"Candidates in priority order: {order}")
    print(f"Dry run: {args.dry_run}")
    print(f"Keep all models: {args.keep_all}")
    print()

    # Load existing leaderboard
    all_metrics = []
    if LEADERBOARD_PATH.exists():
        with open(LEADERBOARD_PATH) as f:
            lb = json.load(f)
            all_metrics = lb.get("candidates", [])
            print(f"Loaded existing leaderboard: {len(all_metrics)} entries")

    # Process each candidate
    for name in order:
        candidate = candidates_by_name[name]
        repo_id = candidate["repo_id"]

        # Determine model directory name
        # For mlx-community candidates, use the name directly
        # For others, download to Models/<name>/
        model_dir_name = name
        model_dir = MODELS_DIR / model_dir_name

        print(f"\n{'='*60}")
        print(f"Candidate: {name}")
        print(f"Repo: {repo_id}")
        print(f"{'='*60}")

        if args.retry_failed:
            for rt in ("python", "mlx"):
                if archive_failed_checkpoint(name, rt):
                    # Stale metrics for the archived run must not survive in
                    # the leaderboard while the retry is pending.
                    all_metrics = [am for am in all_metrics
                                   if not (am["name"] == name and am["runtime"] == rt)]

        # Determine runtimes to test
        compat_info = compat_by_name.get(name, {})
        runtimes_to_test = compat_info.get("runtimes", ["python"])

        # Filter to runtimes we can actually test
        # python (sentence-transformers) is the primary runtime for all models
        # mlx is tested only for mlx-community candidates where mlx_lm can load them
        # coreml is deferred to the Swift EmbeddingBench (separate native path)
        testable_runtimes = []
        for rt in runtimes_to_test:
            if rt == "python":
                testable_runtimes.append("python")
            elif rt == "mlx":
                # Only attempt MLX for mlx-community repos or if mlx is installed
                if "mlx-community" in repo_id:
                    testable_runtimes.append("mlx")
                else:
                    print(f"  MLX runtime: skipped (no pre-converted mlx-community version)")
            elif rt == "coreml":
                print(f"  Core ML runtime: deferred to Swift EmbeddingBench (not in streaming pipeline)")

        if not testable_runtimes:
            print(f"  SKIP — no testable runtimes (compat: {compat_info.get('classification', 'unknown')})")
            write_metadata(name, candidate, model_dir, False, False, 0, [],
                         error="no_testable_runtimes")
            continue

        # Skip if already benchmarked
        if args.skip_existing:
            already = all(is_benchmarked(name, rt) for rt in testable_runtimes)
            if already:
                print(f"  SKIP — all checkpoints exist")
                for rt in testable_runtimes:
                    bench_path = candidate_checkpoint_dir(name, rt) / "benchmark.json"
                    if bench_path.exists():
                        with open(bench_path) as f:
                            bench = json.load(f)
                        m = extract_metrics(bench)
                        if m and not any(am["name"] == name and am["runtime"] == rt for am in all_metrics):
                            m["stability_by_type"] = extract_stability_by_type(bench)
                            all_metrics.append(m)
                continue

        # Check if any model is on disk (for pre-existing models we should NOT delete)
        # The actual download happens per-runtime below
        pre_existing = model_dir.exists() and (model_dir / "config.json").exists()
        was_on_disk = pre_existing

        if args.dry_run:
            print(f"  [DRY RUN] Would benchmark with runtimes: {testable_runtimes}")
            continue

        (RESULTS_DIR / name).mkdir(parents=True, exist_ok=True)

        start_time = time.time()
        runtimes_ok = []
        downloaded = False
        downloaded_dirs = []

        for rt in testable_runtimes:
            rt_output_dir = candidate_checkpoint_dir(name, rt)
            rt_output_dir.mkdir(parents=True, exist_ok=True)

            if is_benchmarked(name, rt) and args.skip_existing:
                print(f"  [{rt}] SKIP — checkpoint exists")
                bench_path = rt_output_dir / "benchmark.json"
                with open(bench_path) as f:
                    bench = json.load(f)
                m = extract_metrics(bench)
                if m:
                    m["stability_by_type"] = extract_stability_by_type(bench)
                    all_metrics = [am for am in all_metrics
                                   if not (am["name"] == name and am["runtime"] == rt)]
                    all_metrics.append(m)
                    runtimes_ok.append(rt)
                continue

            # Determine the model directory for this runtime
            # Python (sentence-transformers) needs the HF format (config.json)
            # MLX needs the mlx-community format
            rt_model_dir = model_dir
            if rt == "python" and not (model_dir / "config.json").exists():
                # Need to download the HF model — use a separate dir
                rt_model_dir = MODELS_DIR / f"{name}-hf"
                if not rt_model_dir.exists():
                    print(f"  [{rt}] Downloading HF model → {rt_model_dir}")
                    success = download_model(repo_id, rt_model_dir, hf_token)
                    if not success:
                        print(f"  [{rt}] FAILED — download failed")
                        continue
                    downloaded = True
                    downloaded_dirs.append(rt_model_dir)
                else:
                    print(f"  [{rt}] HF model already on disk: {rt_model_dir}")
            elif rt == "mlx" and not model_dir.exists():
                rt_model_dir = model_dir
                print(f"  [{rt}] Downloading MLX model → {rt_model_dir}")
                success = download_model(repo_id, rt_model_dir, hf_token)
                if not success:
                    print(f"  [{rt}] FAILED — download failed")
                    continue
                downloaded = True
                downloaded_dirs.append(rt_model_dir)

            eval_ok = run_benchmark_subprocess(
                repo_id, name, rt_model_dir, rt_output_dir, rt, hf_token
            )

            if eval_ok:
                bench_path = rt_output_dir / "benchmark.json"
                with open(bench_path) as f:
                    bench = json.load(f)
                m = extract_metrics(bench)
                if m:
                    m["stability_by_type"] = extract_stability_by_type(bench)
                    # Update or add
                    all_metrics = [am for am in all_metrics
                                   if not (am["name"] == name and am["runtime"] == rt)]
                    all_metrics.append(m)
                    runtimes_ok.append(rt)
                    print(f"  [{rt}] OK — score components: "
                          f"quality={m['quality_score']:.3f} "
                          f"stability={m['stability_mean']:.3f} "
                          f"latency={m['cold_load_time']:.2f}s")
            else:
                print(f"  [{rt}] FAILED")

        elapsed = time.time() - start_time

        # Update leaderboard
        if runtimes_ok:
            leaderboard = update_leaderboard(all_metrics)
            print(f"\n  Current Leaderboard (top 5):")
            sorted_metrics = sorted(all_metrics, key=lambda m: -m.get("overall_score", 0))
            for i, m in enumerate(sorted_metrics[:5]):
                marker = " ←" if m["name"] == name else ""
                print(f"    {i+1}. {m['name']:30s} ({m['runtime']:7s}) "
                      f"score={m.get('overall_score', 0):.3f}{marker}")

        write_metadata(name, candidate, model_dir, downloaded,
                       bool(runtimes_ok), elapsed, runtimes_ok)

        # Evict downloaded models (never pre-existing ones)
        if downloaded and not args.keep_all:
            for d in downloaded_dirs:
                print(f"  Deleting downloaded model: {d}")
                shutil.rmtree(d, ignore_errors=True)
            clean_hf_cache(repo_id)
            print(f"  Models evicted. Disk freed.")
        elif was_on_disk:
            print(f"  Model was pre-existing — NOT deleting.")

    # Final leaderboard (never write artifacts during a dry run)
    if all_metrics and not args.dry_run:
        print(f"\n{'='*60}")
        print("FINAL LEADERBOARD")
        print(f"{'='*60}")
        update_leaderboard(all_metrics)

        # Generate summary markdown
        generate_summary_md(all_metrics)

        # Print top 3
        sorted_metrics = sorted(all_metrics, key=lambda m: -m.get("overall_score", 0))
        print(f"\nTop 3 candidates:")
        for i, m in enumerate(sorted_metrics[:3]):
            print(f"  {i+1}. {m['name']} ({m['runtime']}) — score={m.get('overall_score', 0):.3f}")


def generate_summary_md(all_metrics):
    """Generate summary.md with recommendations."""
    from collections import defaultdict

    lines = []
    lines.append("# NeuralCompose Embedding Benchmark Summary")
    lines.append("")
    lines.append(f"**Generated:** {datetime.now(timezone.utc).isoformat()}")
    lines.append(f"**Total evaluations:** {len(all_metrics)}")
    lines.append("")

    # Group by runtime
    by_runtime = defaultdict(list)
    for m in all_metrics:
        by_runtime[m["runtime"]].append(m)

    lines.append("## Evaluations by Runtime")
    lines.append("")
    for rt, models in sorted(by_runtime.items()):
        lines.append(f"- **{rt}**: {len(models)} models")
    lines.append("")

    # Top candidates per category
    valid = [m for m in all_metrics if m.get("failure_rate", 0) < 1]
    if valid:
        lines.append("## Recommendations")
        lines.append("")

        # Best overall
        best_overall = max(valid, key=lambda m: m.get("overall_score", 0))
        lines.append(f"### Best Overall (weighted score)")
        lines.append(f"**{best_overall['name']}** ({best_overall['runtime']}) — score: {best_overall.get('overall_score', 0):.3f}")
        lines.append("")

        # Highest quality
        best_quality = max(valid, key=lambda m: m.get("quality_score", 0))
        lines.append(f"### Highest Quality")
        lines.append(f"**{best_quality['name']}** ({best_quality['runtime']}) — quality: {best_quality.get('quality_score', 0):.4f}")
        lines.append("")

        # Best stability (ASR robustness)
        best_stability = max(valid, key=lambda m: m.get("stability_mean", 0))
        lines.append(f"### Best Robustness to ASR Noise")
        lines.append(f"**{best_stability['name']}** ({best_stability['runtime']}) — stability: {best_stability.get('stability_mean', 0):.4f}")
        lines.append("")

        # Fastest
        fastest = min(valid, key=lambda m: m.get("cold_load_time", float('inf')))
        lines.append(f"### Fastest (cold load)")
        lines.append(f"**{fastest['name']}** ({fastest['runtime']}) — load: {fastest.get('cold_load_time', 0):.2f}s")
        lines.append("")

        # Highest throughput
        best_throughput = max(valid, key=lambda m: m.get("embeddings_per_second", 0))
        lines.append(f"### Highest Throughput")
        lines.append(f"**{best_throughput['name']}** ({best_throughput['runtime']}) — {best_throughput.get('embeddings_per_second', 0):.0f} emb/s")
        lines.append("")

        # Lowest memory
        lowest_mem = min(valid, key=lambda m: m.get("peak_rss_mb", float('inf')))
        lines.append(f"### Lowest Memory")
        lines.append(f"**{lowest_mem['name']}** ({lowest_mem['runtime']}) — RSS: {lowest_mem.get('peak_rss_mb', 0):.0f}MB")
        lines.append("")

        # Best multilingual (filter by models that support multilingual)
        multilingual_names = {
            "multilingual-e5-small", "multilingual-e5-base", "multilingual-e5-large",
            "bge-m3", "jina-embeddings-v3", "Qwen3-Embedding-0.6B"
        }
        multilingual = [m for m in valid if m["name"] in multilingual_names]
        if multilingual:
            best_multi = max(multilingual, key=lambda m: m.get("quality_score", 0))
            lines.append(f"### Best Multilingual")
            lines.append(f"**{best_multi['name']}** ({best_multi['runtime']}) — quality: {best_multi.get('quality_score', 0):.4f}")
            lines.append("")

        # Best per runtime
        for rt in ["python", "mlx", "coreml"]:
            rt_models = [m for m in valid if m["runtime"] == rt]
            if rt_models:
                best_rt = max(rt_models, key=lambda m: m.get("overall_score", 0))
                lines.append(f"### Best {rt.upper()}")
                lines.append(f"**{best_rt['name']}** — score: {best_rt.get('overall_score', 0):.3f}")
                lines.append("")

        # Pareto frontier
        pareto = compute_pareto(valid)
        lines.append(f"### Pareto-Optimal Candidates")
        lines.append(f"")
        if pareto:
            for p in pareto:
                lines.append(f"- **{p}**")
        else:
            lines.append(f"- (insufficient data)")
        lines.append("")

        # Tradeoffs
        lines.append(f"## Tradeoffs")
        lines.append(f"")
        lines.append(f"NeuralCompose's primary use case is EEG-driven communication, where:")
        lines.append(f"- **Latency** is the binding constraint (real-time interaction)")
        lines.append(f"- **ASR robustness** is critical (input comes from speech recognition)")
        lines.append(f"- **Memory** must fit alongside the MLX LLM in 16GB")
        lines.append(f"- **Quality** matters for retrieval and replay accuracy")
        lines.append(f"")
        lines.append(f"The weighted score reflects these priorities:")
        lines.append(f"- Stability (ASR robustness): {SCORE_WEIGHTS['stability']}")
        lines.append(f"- Quality: {SCORE_WEIGHTS['quality']}")
        lines.append(f"- Latency: {SCORE_WEIGHTS['latency']}")
        lines.append(f"- Throughput: {SCORE_WEIGHTS['throughput']}")
        lines.append(f"- Memory: {SCORE_WEIGHTS['memory']}")
        lines.append(f"- Consistency: {SCORE_WEIGHTS['consistency']}")
        lines.append(f"")
        lines.append(f"Review the Pareto frontier to identify candidates that are not dominated")
        lines.append(f"on any single objective — these are the models worth keeping on disk.")
        lines.append("")

    with open(SUMMARY_MD_PATH, "w") as f:
        f.write("\n".join(lines))
    print(f"  Summary MD: {SUMMARY_MD_PATH}")


if __name__ == "__main__":
    main()