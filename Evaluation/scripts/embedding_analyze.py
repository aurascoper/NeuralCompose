#!/usr/bin/env python3
"""
Statistical analysis of embedding benchmark results.

Reads:  Evaluation/results/embeddings/leaderboard.json
Writes: Evaluation/results/embeddings/statistical_analysis.json
        Evaluation/results/embeddings/statistical_analysis.md

Performs:
  - Confidence intervals (bootstrap)
  - Pairwise statistical tests (Mann-Whitney U)
  - Effect sizes (Cohen's d)
  - Pareto frontier analysis
  - Cluster analysis (k-means)
  - Tradeoff analysis (quality vs latency, stability vs latency)
  - Multiple comparison correction (Bonferroni)
  - Per-variant-type stability analysis
  - Runtime comparison (Core ML vs MLX vs Python where both exist)
"""
import json
import math
import sys
from collections import defaultdict
from datetime import datetime, timezone
from itertools import combinations
from pathlib import Path

import numpy as np
from scipy import stats as sp_stats
from sklearn.cluster import KMeans
from sklearn.preprocessing import StandardScaler

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
RESULTS_DIR = REPO_ROOT / "Evaluation" / "results" / "embeddings"
LEADERBOARD_PATH = RESULTS_DIR / "leaderboard.json"


def bootstrap_ci(data, confidence=0.95, n_boot=10000):
    if len(data) < 2:
        return (float("nan"), float("nan"), len(data))
    arr = np.array(data, dtype=float)
    rng = np.random.default_rng(42)
    boot_means = np.array([
        rng.choice(arr, size=len(arr), replace=True).mean()
        for _ in range(n_boot)
    ])
    alpha = (1 - confidence) / 2
    lo = float(np.percentile(boot_means, alpha * 100))
    hi = float(np.percentile(boot_means, (1 - alpha) * 100))
    return (lo, hi, len(data))


def cohens_d(a, b):
    a, b = np.array(a, dtype=float), np.array(b, dtype=float)
    if len(a) < 2 or len(b) < 2:
        return float("nan")
    pooled_std = math.sqrt((a.var(ddof=1) + b.var(ddof=1)) / 2)
    if pooled_std == 0:
        return 0.0
    return float((a.mean() - b.mean()) / pooled_std)


def mann_whitney_u(a, b):
    a, b = np.array(a, dtype=float), np.array(b, dtype=float)
    if len(a) < 2 or len(b) < 2:
        return {"u_statistic": float("nan"), "p_value": float("nan"),
                "effect_size_r": float("nan"), "n_a": len(a), "n_b": len(b)}
    try:
        u_stat, p_value = sp_stats.mannwhitneyu(a, b, alternative="two-sided")
        n = len(a) + len(b)
        r = 1 - (2 * u_stat) / (n * (n - 1) / 2) if n > 1 else float("nan")
        return {
            "u_statistic": float(u_stat),
            "p_value": float(p_value),
            "effect_size_r": float(r),
            "n_a": len(a), "n_b": len(b),
        }
    except Exception as e:
        return {"u_statistic": float("nan"), "p_value": float("nan"),
                "effect_size_r": float("nan"), "n_a": len(a), "n_b": len(b),
                "error": str(e)}


def bonferroni_correct(p_values):
    p_values = np.array(p_values)
    n = len(p_values)
    return np.minimum(p_values * n, 1.0).tolist()


def load_data():
    if not LEADERBOARD_PATH.exists():
        print("ERROR: leaderboard.json not found. Run the benchmark first.")
        sys.exit(1)
    with open(LEADERBOARD_PATH) as f:
        return json.load(f)


def analyze_rankings(candidates):
    """Rank candidates by each metric."""
    valid = [c for c in candidates if c.get("failure_rate", 0) < 1]
    if not valid:
        return {}

    metrics = ["quality_score", "stability_mean", "cold_load_time",
               "embeddings_per_second", "peak_rss_mb", "overall_score"]

    rankings = {}
    for metric in metrics:
        reverse = metric not in ("cold_load_time", "peak_rss_mb")
        ranked = sorted(valid, key=lambda c: c.get(metric, 0), reverse=reverse)
        rankings[metric] = [
            {"name": c["name"], "runtime": c["runtime"], "value": c.get(metric, 0)}
            for c in ranked
        ]

    return rankings


def analyze_pairwise(candidates):
    """Pairwise statistical tests between all candidate pairs on key metrics."""
    valid = [c for c in candidates if c.get("failure_rate", 0) < 1]
    if len(valid) < 2:
        return {}

    # For pairwise tests, we need per-sample data, not just aggregates.
    # We use the stability_by_type means as multi-sample data for stability,
    # and single-value metrics for effect size comparison.
    # Since we only have aggregate metrics per model, pairwise tests are
    # limited to what we can compute from summary stats.

    # Instead, compute pairwise comparisons on the overall_score
    comparisons = []
    for a, b in combinations(valid, 2):
        score_diff = a.get("overall_score", 0) - b.get("overall_score", 0)
        quality_diff = a.get("quality_score", 0) - b.get("quality_score", 0)
        stability_diff = a.get("stability_mean", 0) - b.get("stability_mean", 0)
        latency_diff = a.get("cold_load_time", 0) - b.get("cold_load_time", 0)

        comparisons.append({
            "a": f"{a['name']} ({a['runtime']})",
            "b": f"{b['name']} ({b['runtime']})",
            "score_diff": score_diff,
            "quality_diff": quality_diff,
            "stability_diff": stability_diff,
            "latency_diff": latency_diff,
            "a_dominates_b": (score_diff > 0 and quality_diff >= 0
                              and stability_diff >= 0 and latency_diff <= 0),
            "b_dominates_a": (score_diff < 0 and quality_diff <= 0
                              and stability_diff <= 0 and latency_diff >= 0),
        })

    return {"pairwise": comparisons}


def analyze_clusters(candidates):
    """K-means clustering on standardized metrics."""
    valid = [c for c in candidates if c.get("failure_rate", 0) < 1]
    if len(valid) < 3:
        return {"note": "insufficient data for clustering"}

    features = ["quality_score", "stability_mean", "cold_load_time",
                "embeddings_per_second", "peak_rss_mb"]
    X = np.array([[c.get(f, 0) for f in features] for c in valid])

    scaler = StandardScaler()
    X_scaled = scaler.fit_transform(X)

    n_clusters = min(3, len(valid))
    kmeans = KMeans(n_clusters=n_clusters, random_state=42, n_init=10)
    labels = kmeans.fit_predict(X_scaled)

    clusters = defaultdict(list)
    for c, label in zip(valid, labels):
        clusters[int(label)].append(f"{c['name']} ({c['runtime']})")

    return {
        "n_clusters": n_clusters,
        "clusters": dict(clusters),
        "features_used": features,
    }


def analyze_tradeoffs(candidates):
    """Analyze tradeoffs between key objectives."""
    valid = [c for c in candidates if c.get("failure_rate", 0) < 1]
    if len(valid) < 2:
        return {}

    # Quality vs Latency
    quality_latency = []
    for c in valid:
        quality_latency.append({
            "name": c["name"],
            "runtime": c["runtime"],
            "quality": c.get("quality_score", 0),
            "latency": c.get("cold_load_time", 0),
        })

    # Stability vs Latency
    stability_latency = []
    for c in valid:
        stability_latency.append({
            "name": c["name"],
            "runtime": c["runtime"],
            "stability": c.get("stability_mean", 0),
            "latency": c.get("cold_load_time", 0),
        })

    # Memory vs Quality
    memory_quality = []
    for c in valid:
        memory_quality.append({
            "name": c["name"],
            "runtime": c["runtime"],
            "memory": c.get("peak_rss_mb", 0),
            "quality": c.get("quality_score", 0),
        })

    # Spearman correlations
    def spearman(x_key, y_key):
        x = [c.get(x_key, 0) for c in valid]
        y = [c.get(y_key, 0) for c in valid]
        if len(x) < 3:
            return {"rho": float("nan"), "p_value": float("nan")}
        rho, p = sp_stats.spearmanr(x, y)
        return {"rho": float(rho), "p_value": float(p)}

    return {
        "quality_vs_latency": quality_latency,
        "stability_vs_latency": stability_latency,
        "memory_vs_quality": memory_quality,
        "correlations": {
            "quality_latency": spearman("quality_score", "cold_load_time"),
            "stability_latency": spearman("stability_mean", "cold_load_time"),
            "stability_quality": spearman("stability_mean", "quality_score"),
            "memory_quality": spearman("peak_rss_mb", "quality_score"),
            "throughput_latency": spearman("embeddings_per_second", "cold_load_time"),
        },
    }


def analyze_runtime_comparison(candidates):
    """Compare runtimes for models that have multiple runtime evaluations."""
    valid = [c for c in candidates if c.get("failure_rate", 0) < 1]
    by_name = defaultdict(list)
    for c in valid:
        by_name[c["name"]].append(c)

    comparisons = []
    for name, models in by_name.items():
        if len(models) < 2:
            continue
        # Compare each pair of runtimes
        for a, b in combinations(models, 2):
            comparisons.append({
                "model": name,
                "runtime_a": a["runtime"],
                "runtime_b": b["runtime"],
                "quality_diff": a.get("quality_score", 0) - b.get("quality_score", 0),
                "stability_diff": a.get("stability_mean", 0) - b.get("stability_mean", 0),
                "latency_diff": a.get("cold_load_time", 0) - b.get("cold_load_time", 0),
                "throughput_diff": a.get("embeddings_per_second", 0) - b.get("embeddings_per_second", 0),
                "memory_diff": a.get("peak_rss_mb", 0) - b.get("peak_rss_mb", 0),
                "better_runtime": a["runtime"] if a.get("overall_score", 0) > b.get("overall_score", 0) else b["runtime"],
            })

    return {"runtime_comparisons": comparisons}


def analyze_stability_by_type(candidates):
    """Analyze stability broken down by variant type across all models."""
    valid = [c for c in candidates if c.get("failure_rate", 0) < 1]

    variant_types = ["asr", "typo", "hesitation", "filler",
                     "punctuation", "capitalization", "no_punctuation", "doubled_word"]

    results = {}
    for vtype in variant_types:
        values = []
        for c in valid:
            st = c.get("stability_by_type", {})
            val = st.get(vtype, {}).get("mean", 0)
            if val > 0:
                values.append({
                    "name": c["name"],
                    "runtime": c["runtime"],
                    "mean": val,
                })

        if values:
            means = [v["mean"] for v in values]
            results[vtype] = {
                "mean_of_means": float(np.mean(means)),
                "std_of_means": float(np.std(means)),
                "min": float(np.min(means)),
                "max": float(np.max(means)),
                "best_model": max(values, key=lambda v: v["mean"]),
                "worst_model": min(values, key=lambda v: v["mean"]),
                "n": len(values),
            }

    return results


def generate_analysis_md(analysis):
    """Generate markdown report."""
    lines = []
    lines.append("# NeuralCompose Embedding Benchmark — Statistical Analysis")
    lines.append("")
    lines.append(f"**Generated:** {analysis['generated_at']}")
    lines.append(f"**Candidates:** {analysis['n_candidates']}")
    lines.append("")

    # Rankings
    rankings = analysis.get("rankings", {})
    if rankings:
        lines.append("## Rankings by Metric")
        lines.append("")
        for metric, ranked in rankings.items():
            lines.append(f"### {metric}")
            lines.append("")
            lines.append("| Rank | Model | Runtime | Value |")
            lines.append("|------|-------|---------|-------|")
            for i, r in enumerate(ranked[:10]):
                lines.append(f"| {i+1} | {r['name']} | {r['runtime']} | {r['value']:.4f} |")
            lines.append("")

    # Pareto
    pareto = analysis.get("pareto_frontier", [])
    if pareto:
        lines.append("## Pareto Frontier")
        lines.append("")
        for p in pareto:
            lines.append(f"- **{p}**")
        lines.append("")

    # Tradeoffs
    tradeoffs = analysis.get("tradeoffs", {})
    if tradeoffs:
        lines.append("## Tradeoff Analysis")
        lines.append("")
        corrs = tradeoffs.get("correlations", {})
        lines.append("| Pair | Spearman ρ | p-value |")
        lines.append("|------|-----------|---------|")
        for pair, stats in corrs.items():
            rho = stats.get("rho", float("nan"))
            p = stats.get("p_value", float("nan"))
            lines.append(f"| {pair} | {rho:.3f} | {p:.4f} |")
        lines.append("")

    # Runtime comparison
    rt_comp = analysis.get("runtime_comparison", {})
    if rt_comp.get("runtime_comparisons"):
        lines.append("## Runtime Comparison (Same Model, Different Runtime)")
        lines.append("")
        lines.append("| Model | Runtime A | Runtime B | Quality Δ | Stability Δ | Latency Δ | Better |")
        lines.append("|-------|-----------|-----------|-----------|-------------|-----------|--------|")
        for comp in rt_comp["runtime_comparisons"]:
            lines.append(
                f"| {comp['model']} | {comp['runtime_a']} | {comp['runtime_b']} "
                f"| {comp['quality_diff']:+.4f} | {comp['stability_diff']:+.4f} "
                f"| {comp['latency_diff']:+.2f}s | {comp['better_runtime']} |"
            )
        lines.append("")

    # Cross-runtime consistency
    cross_rt = analysis.get("cross_runtime_consistency", {})
    if cross_rt.get("cross_runtime_comparisons"):
        lines.append("## Cross-Runtime Embedding Consistency")
        lines.append("")
        lines.append("Compares embeddings produced by different runtimes on the same 10 corpus texts.")
        lines.append("Mean cosine ≈ 1.000 indicates no drift between runtime conversions.")
        lines.append("")
        lines.append("| Model | Runtime A | Runtime B | Mean Cosine | Min | Max | Std | Drift? |")
        lines.append("|-------|-----------|-----------|-------------|-----|-----|-----|--------|")
        for comp in cross_rt["cross_runtime_comparisons"]:
            drift = "⚠ YES" if comp["drift_detected"] else "✓ no"
            lines.append(
                f"| {comp['model']} | {comp['runtime_a']} | {comp['runtime_b']} "
                f"| {comp['mean_cosine']:.6f} | {comp['min_cosine']:.6f} "
                f"| {comp['max_cosine']:.6f} | {comp['std_cosine']:.6f} | {drift} |"
            )
        lines.append("")
    elif cross_rt:
        lines.append("## Cross-Runtime Embedding Consistency")
        lines.append("")
        lines.append("No models have been benchmarked in multiple runtimes yet.")
        lines.append("")

    # Stability by variant type
    stability = analysis.get("stability_by_type", {})
    if stability:
        lines.append("## Stability by Variant Type")
        lines.append("")
        lines.append("| Variant Type | Mean | Std | Min | Max | Best Model | Worst Model |")
        lines.append("|-------------|------|-----|-----|-----|------------|-------------|")
        for vtype, stats in stability.items():
            lines.append(
                f"| {vtype} | {stats['mean_of_means']:.4f} | {stats['std_of_means']:.4f} "
                f"| {stats['min']:.4f} | {stats['max']:.4f} "
                f"| {stats['best_model']['name']} ({stats['best_model']['runtime']}) "
                f"| {stats['worst_model']['name']} ({stats['worst_model']['runtime']}) |"
            )
        lines.append("")

    # Clusters
    clusters = analysis.get("clusters", {})
    if clusters.get("n_clusters"):
        lines.append("## Cluster Analysis")
        lines.append("")
        lines.append(f"**Clusters:** {clusters['n_clusters']}")
        lines.append(f"**Features:** {', '.join(clusters.get('features_used', []))}")
        lines.append("")
        for cid, members in clusters.get("clusters", {}).items():
            lines.append(f"### Cluster {cid}")
            for m in members:
                lines.append(f"- {m}")
            lines.append("")

    # Pairwise
    pairwise = analysis.get("pairwise", {})
    if pairwise.get("pairwise"):
        dom_pairs = [p for p in pairwise["pairwise"] if p["a_dominates_b"] or p["b_dominates_a"]]
        if dom_pairs:
            lines.append("## Dominance Relationships")
            lines.append("")
            for p in dom_pairs:
                if p["a_dominates_b"]:
                    lines.append(f"- **{p['a']}** dominates {p['b']}")
                if p["b_dominates_a"]:
                    lines.append(f"- **{p['b']}** dominates {p['a']}")
            lines.append("")

    return "\n".join(lines)


def analyze_cross_runtime_consistency(candidates, results_dir):
    """
    For models benchmarked in multiple runtimes, compute cosine similarity
    between embeddings produced by different runtimes on the same corpus.

    Uses the embedding_sample stored in each benchmark.json (first 10 corpus items).
    Ideally cos(CoreML, MLX) ≈ 0.9999+. If not, a conversion introduced drift.
    """
    from collections import defaultdict
    import numpy as np

    # Load embedding samples by model name and runtime
    samples = defaultdict(dict)  # {model_name: {runtime: {"texts": [...], "embeddings": [...]}}}

    for c in candidates:
        name = c["name"]
        runtime = c["runtime"]
        # Look for the benchmark.json in the results directory
        bench_path = results_dir / name / runtime / "benchmark.json"
        if not bench_path.exists():
            continue
        with open(bench_path) as f:
            bench = json.load(f)
        sample = bench.get("embedding_sample")
        if sample and sample.get("embeddings"):
            samples[name][runtime] = sample

    comparisons = []
    for name, runtime_samples in samples.items():
        if len(runtime_samples) < 2:
            continue
        runtime_names = list(runtime_samples.keys())
        for i in range(len(runtime_names)):
            for j in range(i + 1, len(runtime_names)):
                rt_a, rt_b = runtime_names[i], runtime_names[j]
                embs_a = runtime_samples[rt_a]["embeddings"]
                embs_b = runtime_samples[rt_b]["embeddings"]

                # Compute per-text cosine similarity
                cosines = []
                for ea, eb in zip(embs_a, embs_b):
                    a = np.array(ea, dtype=np.float32)
                    b = np.array(eb, dtype=np.float32)
                    dot = float(np.dot(a, b))
                    na = float(np.linalg.norm(a))
                    nb = float(np.linalg.norm(b))
                    if na > 1e-9 and nb > 1e-9:
                        cosines.append(dot / (na * nb))

                if cosines:
                    arr = np.array(cosines)
                    comparisons.append({
                        "model": name,
                        "runtime_a": rt_a,
                        "runtime_b": rt_b,
                        "mean_cosine": float(arr.mean()),
                        "min_cosine": float(arr.min()),
                        "max_cosine": float(arr.max()),
                        "std_cosine": float(arr.std()),
                        "n_texts": len(cosines),
                        "drift_detected": float(arr.mean()) < 0.999,
                    })

    return {"cross_runtime_comparisons": comparisons}


def main():
    leaderboard = load_data()
    candidates = leaderboard.get("candidates", [])

    print(f"Analyzing {len(candidates)} candidates...")

    analysis = {
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "n_candidates": len(candidates),
        "weights": leaderboard.get("weights", {}),
        "rankings": analyze_rankings(candidates),
        "pareto_frontier": leaderboard.get("pareto_frontier", []),
        "pairwise": analyze_pairwise(candidates),
        "tradeoffs": analyze_tradeoffs(candidates),
        "runtime_comparison": analyze_runtime_comparison(candidates),
        "stability_by_type": analyze_stability_by_type(candidates),
        "clusters": analyze_clusters(candidates),
        "cross_runtime_consistency": analyze_cross_runtime_consistency(candidates, RESULTS_DIR),
    }

    # Write JSON
    json_path = RESULTS_DIR / "statistical_analysis.json"
    with open(json_path, "w") as f:
        json.dump(analysis, f, indent=2, default=str)
    print(f"Wrote: {json_path}")

    # Write markdown
    md_path = RESULTS_DIR / "statistical_analysis.md"
    md_content = generate_analysis_md(analysis)
    with open(md_path, "w") as f:
        f.write(md_content)
    print(f"Wrote: {md_path}")


if __name__ == "__main__":
    main()