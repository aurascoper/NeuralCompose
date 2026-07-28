#!/usr/bin/env python3
"""
Rigorous statistical analysis of benchmark results.

Reads:  Evaluation/results/raw.json (or existing eval data)
Writes: Evaluation/results/statistical_analysis.json
        Evaluation/results/statistical_analysis.md

Performs:
    - Confidence intervals (bootstrap)
    - Pairwise statistical tests (Mann-Whitney U, Welch's t-test)
    - Effect sizes (Cohen's d, rank-biserial correlation)
    - Rankings (latency, throughput, quality, verbosity, failure rates)
    - Pareto frontier analysis
    - Cluster analysis (k-means on standardized metrics)
    - Tradeoff analysis (quality vs latency, memory vs latency)
    - Multiple comparison correction (Bonferroni)

Scientific constraints:
    - Latency and quality are treated as separate objectives
    - Failure modes are analyzed independently
    - Sample sizes are reported explicitly
    - Overclaiming is avoided — insufficient data is stated
"""
import json
import math
import sys
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path

import numpy as np
from scipy import stats as sp_stats
from sklearn.cluster import KMeans
from sklearn.preprocessing import StandardScaler

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
RESULTS_DIR = REPO_ROOT / "Evaluation" / "results"
REPORTS_DIR = REPO_ROOT / "Evaluation" / "reports"


def bootstrap_ci(data, confidence=0.95, n_boot=10000):
    """Bootstrap confidence interval for the mean."""
    if len(data) < 2:
        return (float("nan"), float("nan"), 0)
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
    """Cohen's d effect size with pooled SD."""
    a, b = np.array(a, dtype=float), np.array(b, dtype=float)
    if len(a) < 2 or len(b) < 2:
        return float("nan")
    # Degrees-of-freedom-weighted pooled variance. The unweighted
    # (var_a + var_b) / 2 form coincides with this only when the groups are the
    # same size, and this function accepts arbitrary lengths — so every
    # unequal-n caller was dividing by the wrong denominator.
    n_a, n_b = len(a), len(b)
    pooled_variance = (
        (n_a - 1) * a.var(ddof=1) + (n_b - 1) * b.var(ddof=1)
    ) / (n_a + n_b - 2)
    pooled_std = math.sqrt(pooled_variance)
    mean_difference = a.mean() - b.mean()
    if pooled_std == 0:
        # PROJECT POLICY, not a universal definition. With both samples constant
        # the denominator is zero and Cohen's d is strictly undefined. We report
        # the limiting value — signed infinity — because 0.0 claimed "no effect"
        # for the most extreme separation representable, and nan would discard
        # the direction. Identical constants are the one genuinely zero case.
        #
        # Callers that PERSIST this must convert at the boundary: JSON has no
        # Infinity literal (`json.dumps` emits a bare `Infinity`, which strict
        # parsers reject) and CSV has no convention at all. Decide on a
        # representation before writing it, rather than assuming the reader copes.
        if mean_difference == 0:
            return 0.0
        return float("inf") if mean_difference > 0 else float("-inf")
    return float(mean_difference / pooled_std)


# Above this per-group size the exact Mann-Whitney null distribution is too
# expensive to enumerate, so the asymptotic approximation is used. Stated here
# rather than inherited from SciPy's `auto` threshold, which is a library
# implementation detail and not a contract.
_EXACT_MAX_N = 20

def mann_whitney_u(a, b):
    """Mann-Whitney U test — non-parametric, no normality assumption."""
    a, b = np.array(a, dtype=float), np.array(b, dtype=float)
    if len(a) < 2 or len(b) < 2:
        return {"u_statistic": float("nan"), "p_value": float("nan"),
                "effect_size_r": float("nan"), "n_a": len(a), "n_b": len(b)}
    try:
        # Method chosen explicitly rather than inherited from SciPy's `auto`,
        # whose selection rule has changed across versions and would silently
        # move a reported p-value between releases. Exact is only valid without
        # ties; it is also combinatorial, so it is capped by sample size and the
        # cap is a stated policy rather than a SciPy default.
        combined = np.concatenate([a, b])
        has_ties = len(np.unique(combined)) < len(combined)
        too_large = max(len(a), len(b)) > _EXACT_MAX_N
        method = "asymptotic" if (has_ties or too_large) else "exact"
        u_stat, p_value = sp_stats.mannwhitneyu(
            a, b, alternative="two-sided", method=method)
        # Rank-biserial correlation effect size
        n = len(a) + len(b)
        r = 1 - (2 * u_stat) / (n * (n - 1) / 2) if n > 1 else float("nan")
        return {
            "u_statistic": float(u_stat),
            "p_value": float(p_value),
            "effect_size_r": float(r),
            "n_a": len(a),
            "n_b": len(b),
        }
    except Exception as e:
        return {"u_statistic": float("nan"), "p_value": float("nan"),
                "effect_size_r": float("nan"), "n_a": len(a), "n_b": len(b),
                "error": str(e)}


def welch_t(a, b):
    """Welch's t-test — doesn't assume equal variances."""
    a, b = np.array(a, dtype=float), np.array(b, dtype=float)
    if len(a) < 2 or len(b) < 2:
        return {"t_statistic": float("nan"), "p_value": float("nan"),
                "dof": float("nan"), "n_a": len(a), "n_b": len(b)}
    try:
        t_stat, p_value = sp_stats.ttest_ind(a, b, equal_var=False)
        return {
            "t_statistic": float(t_stat),
            "p_value": float(p_value),
            "dof": float(len(a) + len(b) - 2),
            "n_a": len(a),
            "n_b": len(b),
        }
    except Exception as e:
        return {"t_statistic": float("nan"), "p_value": float("nan"),
                "dof": float("nan"), "n_a": len(a), "n_b": len(b),
                "error": str(e)}


def bonferroni_correct(p_values):
    """Bonferroni correction for multiple comparisons."""
    p_values = np.array(p_values)
    n = len(p_values)
    corrected = np.minimum(p_values * n, 1.0)
    return corrected.tolist()


def load_data():
    raw_path = RESULTS_DIR / "raw.json"
    if not raw_path.exists():
        eval_dirs = sorted(
            [d for d in (REPO_ROOT / "Evaluation").iterdir()
             if d.is_dir() and "generation-eval" in d.name],
            key=lambda d: d.name, reverse=True
        )
        if eval_dirs and (eval_dirs[0] / "data.json").exists():
            raw_path = eval_dirs[0] / "data.json"
            print(f"Using existing eval data from {raw_path}")
        else:
            print("ERROR: No raw.json or eval data found")
            sys.exit(1)

    with open(raw_path) as f:
        return json.load(f)


def extract_per_prompt_metrics(raw_data):
    """Extract per-prompt metrics keyed by candidate name."""
    data = {}
    for c in raw_data.get("candidates", []):
        if c.get("status") != "evaluated":
            continue
        prompts = c.get("prompts", [])
        data[c["name"]] = {
            "first_token_latency": [p["first_token_latency"] for p in prompts],
            "generate_time": [p["generate_time"] for p in prompts],
            "tokens_per_second": [p["tokens_per_second"] for p in prompts],
            "words_per_second": [p.get("words_per_second", 0) for p in prompts],
            "word_count_ratio": [p["word_count_ratio"] for p in prompts],
            "meaning_cosine": [p["meaning_preservation_cosine"] for p in prompts
                              if p.get("meaning_preservation_cosine") is not None],
            "stop_reasons": [p.get("stop_reason", "unknown") for p in prompts],
            "decoder_loop_period": [p.get("decoder_loop_period", 0) for p in prompts],
            "decoder_loop_repeat_count": [p.get("decoder_loop_repeat_count", 1) for p in prompts],
            "prompt_echo_detected": [p.get("prompt_echo_detected", False) for p in prompts],
            "n_prompts": len(prompts),
        }
    return data


def analyze_rankings(metrics_by_candidate):
    """Rank candidates on each dimension independently."""
    candidates = list(metrics_by_candidate.keys())
    if len(candidates) < 1:
        return {}

    rankings = {}

    # Latency: lower is better
    gt_means = {c: np.mean(metrics_by_candidate[c]["generate_time"]) for c in candidates}
    rankings["latency"] = sorted(candidates, key=lambda c: gt_means[c])

    # Throughput: higher is better
    tps_means = {c: np.mean(metrics_by_candidate[c]["tokens_per_second"]) for c in candidates}
    rankings["throughput"] = sorted(candidates, key=lambda c: -tps_means[c])

    # Quality: higher cosine is better
    mc_means = {}
    for c in candidates:
        cosines = metrics_by_candidate[c]["meaning_cosine"]
        mc_means[c] = np.mean(cosines) if cosines else float("nan")
    valid_mc = {c: v for c, v in mc_means.items() if not math.isnan(v)}
    rankings["meaning_preservation"] = sorted(valid_mc.keys(), key=lambda c: -valid_mc[c])

    # Verbosity: lower ratio is better (more concise)
    wcr_means = {c: np.mean(metrics_by_candidate[c]["word_count_ratio"]) for c in candidates}
    rankings["conciseness"] = sorted(candidates, key=lambda c: wcr_means[c])

    # Failure rate: lower is better (composite: maxTokens rate + loop rate + echo rate)
    failure_scores = {}
    for c in candidates:
        n = metrics_by_candidate[c]["n_prompts"]
        if n == 0:
            failure_scores[c] = float("inf")
            continue
        max_tok = sum(1 for s in metrics_by_candidate[c]["stop_reasons"] if s == "maxTokens") / n
        loops = sum(1 for p, r in zip(metrics_by_candidate[c]["decoder_loop_period"],
                                       metrics_by_candidate[c]["decoder_loop_repeat_count"])
                    if p > 0 and r > 2) / n
        echos = sum(metrics_by_candidate[c]["prompt_echo_detected"]) / n
        failure_scores[c] = max_tok + loops + echos
    rankings["stability"] = sorted(candidates, key=lambda c: failure_scores[c])

    # First token latency: lower is better
    ft_means = {c: np.mean(metrics_by_candidate[c]["first_token_latency"]) for c in candidates}
    rankings["first_token_latency"] = sorted(candidates, key=lambda c: ft_means[c])

    return rankings, gt_means, tps_means, mc_means, wcr_means, failure_scores


def analyze_pareto(gt_means, mc_means):
    """Identify Pareto-optimal candidates (minimize latency, maximize cosine)."""
    valid = {c: (gt_means[c], mc_means[c]) for c in mc_means
             if not math.isnan(mc_means.get(c, float("nan"))) and c in gt_means}
    if len(valid) < 2:
        return []

    pareto = []
    for c, (gt, mc) in valid.items():
        dominated = False
        for c2, (gt2, mc2) in valid.items():
            if c == c2:
                continue
            if gt2 <= gt and mc2 >= mc and (gt2 < gt or mc2 > mc):
                dominated = True
                break
        if not dominated:
            pareto.append(c)
    return pareto


def analyze_clusters(metrics_by_candidate):
    """K-means cluster analysis on standardized metrics."""
    candidates = list(metrics_by_candidate.keys())
    if len(candidates) < 2:
        return {"n_clusters": 0, "clusters": {}, "note": "Need ≥2 candidates for clustering"}

    # Build feature matrix
    features = []
    for c in candidates:
        m = metrics_by_candidate[c]
        cosines = m["meaning_cosine"]
        features.append([
            np.mean(m["generate_time"]),
            np.mean(m["tokens_per_second"]),
            np.mean(m["word_count_ratio"]),
            np.mean(cosines) if cosines else 0,
            m["n_prompts"] and sum(1 for s in m["stop_reasons"] if s == "maxTokens") / m["n_prompts"],
        ])

    X = np.array(features)
    scaler = StandardScaler()
    X_scaled = scaler.fit_transform(X)

    n_clusters = min(3, len(candidates))
    kmeans = KMeans(n_clusters=n_clusters, random_state=42, n_init="auto")
    labels = kmeans.fit_predict(X_scaled)

    clusters = {}
    for i, c in enumerate(candidates):
        cluster_id = int(labels[i])
        if cluster_id not in clusters:
            clusters[cluster_id] = []
        clusters[cluster_id].append(c)

    return {
        "n_clusters": n_clusters,
        "clusters": {str(k): v for k, v in clusters.items()},
        "feature_names": ["generate_time", "tokens_per_second", "word_count_ratio",
                         "meaning_cosine", "maxTokens_rate"],
    }


def analyze_tradeoffs(gt_means, tps_means, mc_means, wcr_means):
    """Analyze tradeoffs between key dimensions."""
    candidates = list(gt_means.keys())
    tradeoffs = {}

    # Quality vs latency correlation
    valid_mc = [c for c in candidates if c in mc_means and not math.isnan(mc_means[c])]
    if len(valid_mc) >= 3:
        gt_vals = [gt_means[c] for c in valid_mc]
        mc_vals = [mc_means[c] for c in valid_mc]
        r, p = sp_stats.spearmanr(gt_vals, mc_vals)
        tradeoffs["quality_vs_latency"] = {
            "spearman_r": float(r), "p_value": float(p),
            "interpretation": ("positive correlation: higher quality costs more latency"
                             if r > 0 else "negative or no correlation"),
            "n": len(valid_mc),
        }
    else:
        tradeoffs["quality_vs_latency"] = {
            "note": f"Insufficient data (n={len(valid_mc)}); need ≥3 for correlation",
            "n": len(valid_mc),
        }

    # Verbosity vs quality
    if len(valid_mc) >= 3:
        wcr_vals = [wcr_means[c] for c in valid_mc]
        r, p = sp_stats.spearmanr(wcr_vals, [mc_means[c] for c in valid_mc])
        tradeoffs["verbosity_vs_quality"] = {
            "spearman_r": float(r), "p_value": float(p),
            "n": len(valid_mc),
        }

    # Throughput vs quality
    if len(valid_mc) >= 3:
        tps_vals = [tps_means[c] for c in valid_mc]
        r, p = sp_stats.spearmanr(tps_vals, [mc_means[c] for c in valid_mc])
        tradeoffs["throughput_vs_quality"] = {
            "spearman_r": float(r), "p_value": float(p),
            "n": len(valid_mc),
        }

    return tradeoffs


def generate_report(analysis, raw_data):
    """Generate statistical_analysis.md."""
    lines = []
    lines.append("# Statistical Analysis of Generation Benchmark")
    lines.append("")
    lines.append(f"**Generated:** {analysis['generated_at']}")
    lines.append(f"**Git commit:** {analysis.get('provenance', {}).get('git_commit', 'unknown')}")
    lines.append("")

    candidates = analysis.get("candidates", [])
    n_evaluated = len(candidates)
    n_prompts = analysis.get("total_prompts", 0)

    lines.append("## Sample Size Disclosure")
    lines.append("")
    lines.append(f"- Evaluated candidates: **{n_evaluated}**")
    lines.append(f"- Total prompts per candidate: **{n_prompts}**")
    lines.append(f"- Rewrite-shaped prompts (with cosine): **{analysis.get('n_cosine_prompts', 0)}**")
    lines.append("")

    if n_evaluated < 2:
        lines.append("**WARNING:** Only one candidate was evaluated. Pairwise statistics, "
                     "rankings, and cluster analysis are not meaningful with a single candidate.")
        lines.append("")
    if n_prompts < 30:
        lines.append(f"**Note:** {n_prompts} prompts is a limited sample. "
                     "Confidence intervals are wide and effect size estimates "
                     "should be treated as preliminary. A larger prompt corpus "
                     "(≥50 prompts) would increase statistical power.")
        lines.append("")

    # Rankings
    rankings = analysis.get("rankings", {})
    if rankings:
        lines.append("## Rankings")
        lines.append("")
        for dimension, ranking in rankings.items():
            if ranking:
                lines.append(f"### {dimension.replace('_', ' ').title()}")
                lines.append("")
                for i, c in enumerate(ranking):
                    lines.append(f"{i+1}. {c}")
                lines.append("")

    # Confidence intervals
    lines.append("## Confidence Intervals (95% Bootstrap)")
    lines.append("")
    lines.append("### Generate Time (seconds)")
    lines.append("")
    lines.append("| Candidate | Mean | CI Low | CI High | n |")
    lines.append("|-----------|------|--------|---------|---|")
    for c in candidates:
        ci = c.get("confidence_intervals", {}).get("generate_time", {})
        lines.append(f"| {c['name']} | {c.get('generate_time_mean', 0):.3f} "
                    f"| {ci.get('lo', 0):.3f} | {ci.get('hi', 0):.3f} "
                    f"| {ci.get('n', 0)} |")
    lines.append("")

    lines.append("### Tokens per Second")
    lines.append("")
    lines.append("| Candidate | Mean | CI Low | CI High | n |")
    lines.append("|-----------|------|--------|---------|---|")
    for c in candidates:
        ci = c.get("confidence_intervals", {}).get("tokens_per_second", {})
        lines.append(f"| {c['name']} | {c.get('tokens_per_second_mean', 0):.1f} "
                    f"| {ci.get('lo', 0):.1f} | {ci.get('hi', 0):.1f} "
                    f"| {ci.get('n', 0)} |")
    lines.append("")

    if any(c.get("confidence_intervals", {}).get("meaning_cosine", {}).get("n", 0) > 0
           for c in candidates):
        lines.append("### Meaning Preservation Cosine")
        lines.append("")
        lines.append("| Candidate | Mean | CI Low | CI High | n |")
        lines.append("|-----------|------|--------|---------|---|")
        for c in candidates:
            ci = c.get("confidence_intervals", {}).get("meaning_cosine", {})
            if ci.get("n", 0) > 0:
                lines.append(f"| {c['name']} | {c.get('meaning_cosine_mean', 0):.4f} "
                            f"| {ci.get('lo', 0):.4f} | {ci.get('hi', 0):.4f} "
                            f"| {ci.get('n', 0)} |")
            else:
                lines.append(f"| {c['name']} | — | — | — | 0 |")
        lines.append("")

    # Pairwise tests
    pairwise = analysis.get("pairwise_tests", [])
    if pairwise:
        lines.append("## Pairwise Statistical Tests")
        lines.append("")
        lines.append("### Mann-Whitney U (non-parametric, no normality assumption)")
        lines.append("")
        lines.append("| Pair | Metric | U | p-value | p (Bonf.) | Effect r |")
        lines.append("|------|--------|---|---------|-----------|----------|")
        for t in pairwise:
            lines.append(
                f"| {t['pair']} | {t['metric']} | {t.get('u_statistic', 0):.0f} "
                f"| {t.get('p_value', 0):.4f} | {t.get('p_value_bonferroni', 0):.4f} "
                f"| {t.get('effect_size_r', 0):.3f} |"
            )
        lines.append("")

        # Effect sizes
        lines.append("### Effect Sizes (Cohen's d)")
        lines.append("")
        lines.append("| Pair | Metric | Cohen's d | Interpretation |")
        lines.append("|------|--------|-----------|----------------|")
        for t in pairwise:
            d = t.get("cohens_d", float("nan"))
            if not math.isnan(d):
                interp = "negligible" if abs(d) < 0.2 else \
                         "small" if abs(d) < 0.5 else \
                         "medium" if abs(d) < 0.8 else "large"
                lines.append(f"| {t['pair']} | {t['metric']} | {d:.3f} | {interp} |")
        lines.append("")

    # Pareto frontier
    pareto = analysis.get("pareto_frontier", [])
    if pareto:
        lines.append("## Pareto Frontier")
        lines.append("")
        lines.append("Pareto-optimal candidates (not dominated on both latency and quality):")
        lines.append("")
        for c in pareto:
            lines.append(f"- **{c}**")
        lines.append("")
        dominated = [c["name"] for c in candidates if c["name"] not in pareto]
        if dominated:
            lines.append("Dominated candidates:")
            lines.append("")
            for c in dominated:
                lines.append(f"- {c}")
            lines.append("")

    # Cluster analysis
    clusters = analysis.get("cluster_analysis", {})
    if clusters.get("n_clusters", 0) > 0:
        lines.append("## Cluster Analysis")
        lines.append("")
        lines.append(f"K-means clustering ({clusters['n_clusters']} clusters) on standardized "
                     "metrics (generate time, tokens/sec, word count ratio, cosine, maxTokens rate):")
        lines.append("")
        for cluster_id, members in clusters.get("clusters", {}).items():
            lines.append(f"### Cluster {cluster_id}")
            for m in members:
                lines.append(f"- {m}")
            lines.append("")

    # Tradeoffs
    tradeoffs = analysis.get("tradeoffs", {})
    if tradeoffs:
        lines.append("## Tradeoff Analysis")
        lines.append("")
        for name, vals in tradeoffs.items():
            lines.append(f"### {name.replace('_', ' ').title()}")
            lines.append("")
            if "spearman_r" in vals:
                r = vals["spearman_r"]
                p = vals["p_value"]
                lines.append(f"- Spearman ρ = {r:.3f} (p = {p:.4f}, n = {vals.get('n', 0)})")
                if abs(r) > 0.6:
                    direction = "positive" if r > 0 else "negative"
                    lines.append(f"- **Strong {direction} correlation**")
                elif abs(r) > 0.3:
                    direction = "positive" if r > 0 else "negative"
                    lines.append(f"- Moderate {direction} correlation")
                else:
                    lines.append("- Weak or no correlation")
            elif "note" in vals:
                lines.append(f"- {vals['note']}")
            lines.append("")

    # Failure mode analysis
    lines.append("## Failure Mode Analysis")
    lines.append("")
    lines.append("| Candidate | maxTokens Rate | Decoder Loop Rate | Echo Rate |")
    lines.append("|-----------|---------------|-------------------|-----------|")
    for c in candidates:
        lines.append(
            f"| {c['name']} | {c.get('maxTokens_rate', 0):.1%} "
            f"| {c.get('decoder_loop_rate', 0):.1%} "
            f"| {c.get('echo_rate', 0):.1%} |"
        )
    lines.append("")

    lines.append("## Threats to Validity")
    lines.append("")
    lines.append("1. **Sample size:** With n={} prompts, statistical power is limited. "
                "Bootstrap CIs are used because they don't require normality, but "
                "intervals are necessarily wide.".format(n_prompts))
    lines.append("2. **Single device:** All measurements are from a single M4 Mac. "
                "Results may not generalize to other Apple Silicon variants.")
    lines.append("3. **Single run:** No repeated measures (same prompt run multiple times). "
                "Variance estimates reflect between-prompt variance, not within-prompt noise.")
    lines.append("4. **Prompt corpus bias:** The 26-prompt corpus may not represent "
                "the full distribution of user inputs in an EEG communication context.")
    lines.append("5. **Temperature=0.7:** Results are at a single temperature. "
                "Lower temperatures may reduce variance but also reduce output diversity.")
    lines.append("6. **maxTokens=120:** The generation cap truncates some outputs. "
                "maxTokens stop rate should be interpreted as a failure only if the "
                "model hasn't naturally concluded by then.")
    lines.append("7. **Manual scoring pending:** Meaning preservation, grammar, "
                "instruction following, hallucination, and fluency scores are not "
                "yet available from manual review. The cosine similarity is a proxy "
                "for meaning preservation, not a direct quality measure.")
    lines.append("")

    return "\n".join(lines)


def main():
    raw_data = load_data()
    metrics_by_candidate = extract_per_prompt_metrics(raw_data)

    if not metrics_by_candidate:
        print("No evaluated candidates found.")
        return

    candidates = list(metrics_by_candidate.keys())
    print(f"Analyzing {len(candidates)} candidates: {candidates}")

    # Per-candidate CIs
    candidate_summaries = []
    for c in candidates:
        m = metrics_by_candidate[c]
        gt_lo, gt_hi, gt_n = bootstrap_ci(m["generate_time"])
        tps_lo, tps_hi, tps_n = bootstrap_ci(m["tokens_per_second"])
        wcr_lo, wcr_hi, wcr_n = bootstrap_ci(m["word_count_ratio"])
        mc_lo, mc_hi, mc_n = bootstrap_ci(m["meaning_cosine"]) if m["meaning_cosine"] else (float("nan"), float("nan"), 0)

        n = m["n_prompts"]
        max_tok_rate = sum(1 for s in m["stop_reasons"] if s == "maxTokens") / n if n else 0
        loop_rate = sum(1 for p, r in zip(m["decoder_loop_period"], m["decoder_loop_repeat_count"])
                       if p > 0 and r > 2) / n if n else 0
        echo_rate = sum(m["prompt_echo_detected"]) / n if n else 0

        candidate_summaries.append({
            "name": c,
            "generate_time_mean": float(np.mean(m["generate_time"])),
            "tokens_per_second_mean": float(np.mean(m["tokens_per_second"])),
            "word_count_ratio_mean": float(np.mean(m["word_count_ratio"])),
            "meaning_cosine_mean": float(np.mean(m["meaning_cosine"])) if m["meaning_cosine"] else None,
            "maxTokens_rate": max_tok_rate,
            "decoder_loop_rate": loop_rate,
            "echo_rate": echo_rate,
            "n_prompts": n,
            "confidence_intervals": {
                "generate_time": {"lo": gt_lo, "hi": gt_hi, "n": gt_n},
                "tokens_per_second": {"lo": tps_lo, "hi": tps_hi, "n": tps_n},
                "word_count_ratio": {"lo": wcr_lo, "hi": wcr_hi, "n": wcr_n},
                "meaning_cosine": {"lo": mc_lo, "hi": mc_hi, "n": mc_n},
            },
        })

    # Rankings
    rankings, gt_means, tps_means, mc_means, wcr_means, failure_scores = \
        analyze_rankings(metrics_by_candidate)

    # Pareto
    pareto = analyze_pareto(gt_means, mc_means)

    # Pairwise tests
    pairwise_tests = []
    if len(candidates) >= 2:
        all_p_values = []
        for i, a in enumerate(candidates):
            for b in candidates[i+1:]:
                for metric_name, metric_key in [
                    ("generate_time", "generate_time"),
                    ("tokens_per_second", "tokens_per_second"),
                    ("word_count_ratio", "word_count_ratio"),
                ]:
                    vals_a = metrics_by_candidate[a][metric_key]
                    vals_b = metrics_by_candidate[b][metric_key]
                    mw = mann_whitney_u(vals_a, vals_b)
                    d = cohens_d(vals_a, vals_b)
                    pairwise_tests.append({
                        "pair": f"{a}_vs_{b}",
                        "metric": metric_name,
                        "u_statistic": mw["u_statistic"],
                        "p_value": mw["p_value"],
                        "effect_size_r": mw["effect_size_r"],
                        "cohens_d": d,
                        "n_a": mw["n_a"],
                        "n_b": mw["n_b"],
                    })
                    all_p_values.append(mw["p_value"])

        # Bonferroni correction
        corrected = bonferroni_correct(all_p_values)
        for i, t in enumerate(pairwise_tests):
            t["p_value_bonferroni"] = corrected[i]

    # Clusters
    cluster_result = analyze_clusters(metrics_by_candidate)

    # Tradeoffs
    tradeoffs = analyze_tradeoffs(gt_means, tps_means, mc_means, wcr_means)

    # Count cosine prompts
    n_cosine = 0
    for c in candidates:
        n_cosine = max(n_cosine, len(metrics_by_candidate[c]["meaning_cosine"]))

    analysis = {
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "provenance": raw_data.get("provenance", {}),
        "total_prompts": max(metrics_by_candidate[c]["n_prompts"] for c in candidates) if candidates else 0,
        "n_evaluated": len(candidates),
        "n_cosine_prompts": n_cosine,
        "candidates": candidate_summaries,
        "rankings": rankings,
        "pareto_frontier": pareto,
        "pairwise_tests": pairwise_tests,
        "cluster_analysis": cluster_result,
        "tradeoffs": tradeoffs,
    }

    # Write JSON
    REPORTS_DIR.mkdir(parents=True, exist_ok=True)
    RESULTS_DIR.mkdir(parents=True, exist_ok=True)
    json_path = RESULTS_DIR / "statistical_analysis.json"
    with open(json_path, "w") as f:
        json.dump(analysis, f, indent=2, default=str, sort_keys=True)
    print(f"Wrote {json_path}")

    # Write markdown
    md_content = generate_report(analysis, raw_data)
    md_path = REPORTS_DIR / "statistical_analysis.md"
    with open(md_path, "w") as f:
        f.write(md_content)
    print(f"Wrote {md_path}")


if __name__ == "__main__":
    main()