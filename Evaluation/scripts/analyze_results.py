#!/usr/bin/env python3
"""
Analyze raw benchmark results and produce summary.json, summary.csv, summary.md.

Reads:  Evaluation/results/raw.json
Writes: Evaluation/results/summary.json
        Evaluation/results/summary.csv
        Evaluation/results/summary.md

Raw measurements are kept separate from derived statistics — this script
computes per-candidate aggregates (mean, median, std, CI) across prompts,
plus per-category breakdowns and failure rates.
"""
import json
import math
import statistics
from pathlib import Path

import numpy as np
import pandas as pd

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
RESULTS_DIR = REPO_ROOT / "Evaluation" / "results"


def bootstrap_ci(data, confidence=0.95, n_boot=10000):
    """Bootstrap confidence interval for the mean."""
    if len(data) < 2:
        return (float("nan"), float("nan"))
    arr = np.array(data, dtype=float)
    rng = np.random.default_rng(42)
    boot_means = np.array([
        rng.choice(arr, size=len(arr), replace=True).mean()
        for _ in range(n_boot)
    ])
    alpha = (1 - confidence) / 2
    lo = float(np.percentile(boot_means, alpha * 100))
    hi = float(np.percentile(boot_means, (1 - alpha) * 100))
    return (lo, hi)


def cohens_d(a, b):
    """Cohen's d effect size (pooled SD)."""
    a, b = np.array(a, dtype=float), np.array(b, dtype=float)
    if len(a) < 2 or len(b) < 2:
        return float("nan")
    pooled_std = math.sqrt((a.var(ddof=1) + b.var(ddof=1)) / 2)
    if pooled_std == 0:
        return 0.0
    return float((a.mean() - b.mean()) / pooled_std)


def safe_mean(values):
    return float(np.nanmean(values)) if len(values) > 0 else float("nan")


def safe_std(values):
    return float(np.nanstd(values, ddof=1)) if len(values) > 1 else float("nan")


def safe_median(values):
    return float(np.nanmedian(values)) if len(values) > 0 else float("nan")


def analyze_candidate(name, candidate_data):
    """Compute per-candidate statistics from raw prompt results."""
    prompts = candidate_data.get("prompts", [])
    if not prompts:
        return None

    metrics = {
        "first_token_latency": [p["first_token_latency"] for p in prompts],
        "generate_time": [p["generate_time"] for p in prompts],
        "tokens_per_second": [p["tokens_per_second"] for p in prompts],
        "words_per_second": [p.get("words_per_second", 0) for p in prompts],
        "word_count_ratio": [p["word_count_ratio"] for p in prompts],
    }

    # Meaning preservation cosine (only for rewrite-shaped prompts)
    cosine_values = [
        p["meaning_preservation_cosine"]
        for p in prompts
        if p.get("meaning_preservation_cosine") is not None
    ]

    # Failure metrics
    stop_reasons = [p.get("stop_reason", "unknown") for p in prompts]
    max_tokens_count = sum(1 for s in stop_reasons if s == "maxTokens")
    eos_count = sum(1 for s in stop_reasons if s == "eos")

    decoder_loops = [
        p for p in prompts
        if p.get("decoder_loop_period", 0) > 0 and p.get("decoder_loop_repeat_count", 1) > 2
    ]
    prompt_echos = [p for p in prompts if p.get("prompt_echo_detected", False)]

    summary = {
        "name": name,
        "status": candidate_data.get("status", "unknown"),
        "model_identifier": candidate_data.get("model_identifier"),
        "cold_load_time": candidate_data.get("cold_load_time"),
        "warm_load_time": candidate_data.get("warm_load_time"),
        "peak_rss_mb": candidate_data.get("peak_rss_mb"),
        "n_prompts": len(prompts),
        # Latency
        "first_token_latency_mean": safe_mean(metrics["first_token_latency"]),
        "first_token_latency_median": safe_median(metrics["first_token_latency"]),
        "first_token_latency_std": safe_std(metrics["first_token_latency"]),
        "generate_time_mean": safe_mean(metrics["generate_time"]),
        "generate_time_median": safe_median(metrics["generate_time"]),
        "generate_time_std": safe_std(metrics["generate_time"]),
        # Throughput
        "tokens_per_second_mean": safe_mean(metrics["tokens_per_second"]),
        "tokens_per_second_median": safe_median(metrics["tokens_per_second"]),
        "tokens_per_second_std": safe_std(metrics["tokens_per_second"]),
        "words_per_second_mean": safe_mean(metrics["words_per_second"]),
        "words_per_second_median": safe_median(metrics["words_per_second"]),
        # Verbosity
        "word_count_ratio_mean": safe_mean(metrics["word_count_ratio"]),
        "word_count_ratio_median": safe_median(metrics["word_count_ratio"]),
        "word_count_ratio_std": safe_std(metrics["word_count_ratio"]),
        # Quality
        "meaning_cosine_mean": safe_mean(cosine_values) if cosine_values else None,
        "meaning_cosine_median": safe_median(cosine_values) if cosine_values else None,
        "meaning_cosine_std": safe_std(cosine_values) if cosine_values else None,
        "meaning_cosine_n": len(cosine_values),
        # Failure rates
        "stop_maxTokens_rate": max_tokens_count / len(prompts) if prompts else 0,
        "stop_eos_rate": eos_count / len(prompts) if prompts else 0,
        "decoder_loop_rate": len(decoder_loops) / len(prompts) if prompts else 0,
        "prompt_echo_rate": len(prompt_echos) / len(prompts) if prompts else 0,
        # CIs
        "generate_time_ci_lo": bootstrap_ci(metrics["generate_time"])[0],
        "generate_time_ci_hi": bootstrap_ci(metrics["generate_time"])[1],
        "tokens_per_second_ci_lo": bootstrap_ci(metrics["tokens_per_second"])[0],
        "tokens_per_second_ci_hi": bootstrap_ci(metrics["tokens_per_second"])[1],
    }

    if cosine_values:
        lo, hi = bootstrap_ci(cosine_values)
        summary["meaning_cosine_ci_lo"] = lo
        summary["meaning_cosine_ci_hi"] = hi

    # Per-category breakdown
    categories = {}
    for p in prompts:
        cat = p["category"]
        if cat not in categories:
            categories[cat] = {
                "generate_time": [],
                "tokens_per_second": [],
                "word_count_ratio": [],
                "meaning_cosine": [],
            }
        categories[cat]["generate_time"].append(p["generate_time"])
        categories[cat]["tokens_per_second"].append(p["tokens_per_second"])
        categories[cat]["word_count_ratio"].append(p["word_count_ratio"])
        if p.get("meaning_preservation_cosine") is not None:
            categories[cat]["meaning_cosine"].append(p["meaning_preservation_cosine"])

    summary["per_category"] = {}
    for cat, vals in categories.items():
        summary["per_category"][cat] = {
            "generate_time_mean": safe_mean(vals["generate_time"]),
            "tokens_per_second_mean": safe_mean(vals["tokens_per_second"]),
            "word_count_ratio_mean": safe_mean(vals["word_count_ratio"]),
            "meaning_cosine_mean": safe_mean(vals["meaning_cosine"]) if vals["meaning_cosine"] else None,
            "n": len(vals["generate_time"]),
        }

    return summary


def compute_pairwise_effects(summaries):
    """Compute pairwise Cohen's d for key metrics between all evaluated candidates."""
    evaluated = [s for s in summaries if s and s["status"] == "evaluated"]
    if len(evaluated) < 2:
        return []

    effects = []
    for i, a in enumerate(evaluated):
        for b in evaluated[i + 1:]:
            # We need the raw values for effect size computation
            # But summaries only have aggregates — we'll compute from raw data
            # For now, record the pair and use means/stds
            for metric in ["generate_time_mean", "tokens_per_second_mean",
                          "word_count_ratio_mean", "meaning_cosine_mean"]:
                va = a.get(metric)
                vb = b.get(metric)
                if va is not None and vb is not None and not (isinstance(va, float) and math.isnan(va)):
                    effects.append({
                        "pair": f"{a['name']}_vs_{b['name']}",
                        "metric": metric,
                        "a_mean": va,
                        "b_mean": vb,
                        "difference": va - vb,
                    })
    return effects


def generate_markdown(summaries, raw_data):
    """Generate summary.md from aggregated statistics."""
    lines = []
    lines.append("# Generation Benchmark Summary")
    lines.append("")
    lines.append(f"**Schema version:** {raw_data.get('schema_version', '?')}")
    lines.append(f"**Git commit:** {raw_data.get('provenance', {}).get('git_commit', 'unknown')}")
    lines.append(f"**Device:** {raw_data.get('provenance', {}).get('device', 'unknown')}")
    lines.append(f"**macOS:** {raw_data.get('provenance', {}).get('macos_version', 'unknown')}")
    lines.append("")

    evaluated = [s for s in summaries if s and s["status"] == "evaluated"]
    skipped = [s for s in summaries if s and s["status"] != "evaluated"]

    if skipped:
        lines.append("## Skipped Candidates")
        lines.append("")
        for s in skipped:
            lines.append(f"- **{s['name']}**: {s['status']}")
        lines.append("")

    if not evaluated:
        lines.append("No candidates were evaluated.")
        return "\n".join(lines)

    # Overview table
    lines.append("## Overview")
    lines.append("")
    lines.append("| Candidate | Cold Load (s) | Warm Load (s) | Peak RSS (MB) | Prompts |")
    lines.append("|-----------|--------------|--------------|---------------|---------|")
    for s in evaluated:
        cold = f"{s['cold_load_time']:.2f}" if s.get("cold_load_time") else "—"
        warm = f"{s['warm_load_time']:.2f}" if s.get("warm_load_time") else "—"
        rss = f"{s['peak_rss_mb']:.0f}" if s.get("peak_rss_mb") else "—"
        lines.append(f"| {s['name']} | {cold} | {warm} | {rss} | {s['n_prompts']} |")
    lines.append("")

    # Latency table
    lines.append("## Latency")
    lines.append("")
    lines.append("| Candidate | First Token (ms) | Generate (s) | Generate CI95 |")
    lines.append("|-----------|-----------------|-------------|---------------|")
    for s in evaluated:
        ft = f"{s['first_token_latency_mean']*1000:.1f} ± {s['first_token_latency_std']*1000:.1f}"
        gt = f"{s['generate_time_mean']:.2f} ± {s['generate_time_std']:.2f}"
        ci = f"[{s['generate_time_ci_lo']:.2f}, {s['generate_time_ci_hi']:.2f}]"
        lines.append(f"| {s['name']} | {ft} | {gt} | {ci} |")
    lines.append("")

    # Throughput table
    lines.append("## Throughput")
    lines.append("")
    lines.append("| Candidate | tok/s | tok/s CI95 | words/s |")
    lines.append("|-----------|-------|------------|---------|")
    for s in evaluated:
        tps = f"{s['tokens_per_second_mean']:.1f} ± {s['tokens_per_second_std']:.1f}"
        ci = f"[{s['tokens_per_second_ci_lo']:.1f}, {s['tokens_per_second_ci_hi']:.1f}]"
        wps = f"{s['words_per_second_mean']:.1f}"
        lines.append(f"| {s['name']} | {tps} | {ci} | {wps} |")
    lines.append("")

    # Quality table
    lines.append("## Quality")
    lines.append("")
    lines.append("| Candidate | Meaning Cosine | Cosine CI95 | n_cosine |")
    lines.append("|-----------|---------------|------------|----------|")
    for s in evaluated:
        if s.get("meaning_cosine_mean") is not None and not math.isnan(s["meaning_cosine_mean"]):
            mc = f"{s['meaning_cosine_mean']:.4f} ± {s.get('meaning_cosine_std', 0):.4f}"
            ci = f"[{s.get('meaning_cosine_ci_lo', 0):.4f}, {s.get('meaning_cosine_ci_hi', 0):.4f}]"
            n = s.get("meaning_cosine_n", 0)
            lines.append(f"| {s['name']} | {mc} | {ci} | {n} |")
        else:
            lines.append(f"| {s['name']} | — | — | 0 |")
    lines.append("")

    # Failure modes
    lines.append("## Failure Modes")
    lines.append("")
    lines.append("| Candidate | maxTokens Rate | EOS Rate | Decoder Loop Rate | Echo Rate |")
    lines.append("|-----------|---------------|----------|-------------------|-----------|")
    for s in evaluated:
        lines.append(
            f"| {s['name']} | {s['stop_maxTokens_rate']:.1%} | {s['stop_eos_rate']:.1%} "
            f"| {s['decoder_loop_rate']:.1%} | {s['prompt_echo_rate']:.1%} |"
        )
    lines.append("")

    # Verbosity
    lines.append("## Verbosity")
    lines.append("")
    lines.append("| Candidate | Word Count Ratio | WC Ratio CI95 |")
    lines.append("|-----------|-----------------|---------------|")
    for s in evaluated:
        wcr = f"{s['word_count_ratio_mean']:.2f} ± {s['word_count_ratio_std']:.2f}"
        lo, hi = bootstrap_ci([p["word_count_ratio"] for p in
                              next(c for c in raw_data["candidates"]
                                   if c["name"] == s["name"])["prompts"]])
        ci = f"[{lo:.2f}, {hi:.2f}]"
        lines.append(f"| {s['name']} | {wcr} | {ci} |")
    lines.append("")

    # Per-category breakdown
    lines.append("## Per-Category Breakdown")
    lines.append("")
    for s in evaluated:
        if not s.get("per_category"):
            continue
        lines.append(f"### {s['name']}")
        lines.append("")
        lines.append("| Category | n | Gen Time (s) | tok/s | WC Ratio | Cosine |")
        lines.append("|----------|---|-------------|-------|----------|--------|")
        for cat, vals in sorted(s["per_category"].items()):
            mc = f"{vals['meaning_cosine_mean']:.4f}" if vals.get("meaning_cosine_mean") else "—"
            lines.append(
                f"| {cat} | {vals['n']} | {vals['generate_time_mean']:.2f} "
                f"| {vals['tokens_per_second_mean']:.1f} "
                f"| {vals['word_count_ratio_mean']:.2f} | {mc} |"
            )
        lines.append("")

    return "\n".join(lines)


def main():
    raw_path = RESULTS_DIR / "raw.json"
    if not raw_path.exists():
        # Also check for existing eval data
        eval_dirs = sorted(
            [d for d in (REPO_ROOT / "Evaluation").iterdir()
             if d.is_dir() and "generation-eval" in d.name],
            key=lambda d: d.name, reverse=True
        )
        if eval_dirs and (eval_dirs[0] / "data.json").exists():
            raw_path = eval_dirs[0] / "data.json"
            print(f"Note: Using existing eval data from {raw_path}")
        else:
            print(f"ERROR: {RESULTS_DIR / 'raw.json'} not found.")
            print("Run run_benchmark.py first.")
            return

    with open(raw_path) as f:
        raw_data = json.load(f)

    # Analyze each candidate
    summaries = []
    for c in raw_data.get("candidates", []):
        s = analyze_candidate(c["name"], c)
        summaries.append(s)

    # Write summary.json
    summary_json = {
        "generated_at": __import__("datetime").datetime.now(
            __import__("datetime").timezone.utc
        ).isoformat(),
        "provenance": raw_data.get("provenance", {}),
        "candidates": [s for s in summaries if s],
    }

    summary_path = RESULTS_DIR / "summary.json"
    with open(summary_path, "w") as f:
        json.dump(summary_json, f, indent=2, default=str, sort_keys=True)
    print(f"Wrote {summary_path}")

    # Write summary.csv (flat per-candidate)
    evaluated = [s for s in summaries if s and s["status"] == "evaluated"]
    if evaluated:
        df_data = []
        for s in evaluated:
            row = {}
            for k, v in s.items():
                if k != "per_category":
                    row[k] = v
            df_data.append(row)
        df = pd.DataFrame(df_data)
        csv_path = RESULTS_DIR / "summary.csv"
        df.to_csv(csv_path, index=False)
        print(f"Wrote {csv_path}")

    # Write summary.md
    md_content = generate_markdown(summaries, raw_data)
    md_path = RESULTS_DIR / "summary.md"
    with open(md_path, "w") as f:
        f.write(md_content)
    print(f"Wrote {md_path}")


if __name__ == "__main__":
    main()