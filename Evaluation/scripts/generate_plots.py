#!/usr/bin/env python3
"""
Generate plots from benchmark results.

Reads:  Evaluation/results/summary.json (or raw.json)
Writes: Evaluation/plots/*.png

Plots:
    latency.png          — first-token + generate time per candidate
    throughput.png       — tokens/sec and words/sec per candidate
    memory.png           — peak RSS and cold load time
    quality.png          — meaning preservation cosine per candidate
    pareto_frontier.png  — quality vs latency Pareto frontier
    failure_modes.png    — stop reason + decoder loop + echo rates
    verbosity.png        — word count ratio per candidate
    category_heatmap.png — per-category generate time heatmap
"""
import argparse
import json
import math
import sys
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np
import pandas as pd

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
RESULTS_DIR = REPO_ROOT / "Evaluation" / "results"
PLOTS_DIR = REPO_ROOT / "Evaluation" / "plots"

# Consistent color palette
COLORS = ["#2196F3", "#FF9800", "#4CAF50", "#E91E63", "#9C27B0",
          "#00BCD4", "#FF5722", "#795548", "#607D8B", "#F44336"]


def load_data():
    """Load summary.json and raw.json."""
    summary_path = RESULTS_DIR / "summary.json"
    raw_path = RESULTS_DIR / "raw.json"

    # Also check for existing eval data
    if not raw_path.exists():
        eval_dirs = sorted(
            [d for d in (REPO_ROOT / "Evaluation").iterdir()
             if d.is_dir() and "generation-eval" in d.name],
            key=lambda d: d.name, reverse=True
        )
        if eval_dirs and (eval_dirs[0] / "data.json").exists():
            raw_path = eval_dirs[0] / "data.json"

    if not summary_path.exists():
        print("summary.json not found. Run analyze_results.py first.")
        sys.exit(1)
    if not raw_path.exists():
        print("raw.json not found. Run run_benchmark.py first.")
        sys.exit(1)

    with open(summary_path) as f:
        summary = json.load(f)
    with open(raw_path) as f:
        raw = json.load(f)

    return summary, raw


def get_evaluated(summary):
    return [s for s in summary["candidates"] if s and s["status"] == "evaluated"]


def plot_latency(evaluated, raw):
    """Bar chart: first-token latency + generate time per candidate."""
    if not evaluated:
        return
    names = [s["name"] for s in evaluated]
    ft_mean = [s["first_token_latency_mean"] * 1000 for s in evaluated]
    ft_std = [s["first_token_latency_std"] * 1000 for s in evaluated]
    gt_mean = [s["generate_time_mean"] for s in evaluated]
    gt_std = [s["generate_time_std"] for s in evaluated]

    fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(14, 5))

    x = np.arange(len(names))
    colors = [COLORS[i % len(COLORS)] for i in range(len(names))]

    ax1.bar(x, ft_mean, yerr=ft_std, capsize=5, color=colors, alpha=0.8)
    ax1.set_ylabel("First Token Latency (ms)")
    ax1.set_title("First Token Latency")
    ax1.set_xticks(x)
    ax1.set_xticklabels(names, rotation=45, ha="right")

    ax2.bar(x, gt_mean, yerr=gt_std, capsize=5, color=colors, alpha=0.8)
    ax2.set_ylabel("Generate Time (s)")
    ax2.set_title("Total Generate Time")
    ax2.set_xticks(x)
    ax2.set_xticklabels(names, rotation=45, ha="right")

    plt.tight_layout()
    plt.savefig(PLOTS_DIR / "latency.png", dpi=150)
    plt.close()
    print("Wrote latency.png")


def plot_throughput(evaluated):
    """Bar chart: tokens/sec and words/sec per candidate."""
    if not evaluated:
        return
    names = [s["name"] for s in evaluated]
    tps_mean = [s["tokens_per_second_mean"] for s in evaluated]
    tps_std = [s["tokens_per_second_std"] for s in evaluated]
    wps_mean = [s["words_per_second_mean"] for s in evaluated]

    fig, ax = plt.subplots(figsize=(10, 5))
    x = np.arange(len(names))
    width = 0.35

    colors1 = [COLORS[i % len(COLORS)] for i in range(len(names))]
    colors2 = [c + "80" for c in colors1]

    bars1 = ax.bar(x - width/2, tps_mean, width, yerr=tps_std, capsize=3,
                   label="tokens/sec", color=colors1, alpha=0.8)
    bars2 = ax.bar(x + width/2, wps_mean, width,
                   label="words/sec", color=colors2, alpha=0.8)

    ax.set_ylabel("Rate")
    ax.set_title("Generation Throughput")
    ax.set_xticks(x)
    ax.set_xticklabels(names, rotation=45, ha="right")
    ax.legend()

    plt.tight_layout()
    plt.savefig(PLOTS_DIR / "throughput.png", dpi=150)
    plt.close()
    print("Wrote throughput.png")


def plot_memory(evaluated):
    """Bar chart: peak RSS + cold load time."""
    if not evaluated:
        return
    names = [s["name"] for s in evaluated]
    rss = [s.get("peak_rss_mb", 0) or 0 for s in evaluated]
    cold = [s.get("cold_load_time", 0) or 0 for s in evaluated]

    fig, (ax1, ax2) = plt.subplots(1, 2, figsize=(12, 5))
    x = np.arange(len(names))
    colors = [COLORS[i % len(COLORS)] for i in range(len(names))]

    ax1.bar(x, rss, color=colors, alpha=0.8)
    ax1.set_ylabel("Peak RSS (MB)")
    ax1.set_title("Memory Usage")
    ax1.set_xticks(x)
    ax1.set_xticklabels(names, rotation=45, ha="right")

    ax2.bar(x, cold, color=colors, alpha=0.8)
    ax2.set_ylabel("Cold Load Time (s)")
    ax2.set_title("Cold Load Time")
    ax2.set_xticks(x)
    ax2.set_xticklabels(names, rotation=45, ha="right")

    plt.tight_layout()
    plt.savefig(PLOTS_DIR / "memory.png", dpi=150)
    plt.close()
    print("Wrote memory.png")


def plot_quality(evaluated, raw):
    """Box plot: meaning preservation cosine per candidate."""
    if not evaluated:
        return

    fig, ax = plt.subplots(figsize=(10, 5))

    data = []
    labels = []
    for s in evaluated:
        # Get raw cosine values
        candidate = next(c for c in raw["candidates"] if c["name"] == s["name"])
        cosines = [p["meaning_preservation_cosine"] for p in candidate["prompts"]
                   if p.get("meaning_preservation_cosine") is not None]
        if cosines:
            data.append(cosines)
            labels.append(s["name"])

    if not data:
        ax.text(0.5, 0.5, "No cosine data available", ha="center", va="center")
    else:
        bp = ax.boxplot(data, tick_labels=labels, patch_artist=True)
        for i, patch in enumerate(bp["boxes"]):
            patch.set_facecolor(COLORS[i % len(COLORS)])
            patch.set_alpha(0.6)

    ax.set_ylabel("Meaning Preservation Cosine")
    ax.set_title("Quality: Meaning Preservation")
    ax.set_xticklabels(labels, rotation=45, ha="right")
    ax.set_ylim(0, 1)

    plt.tight_layout()
    plt.savefig(PLOTS_DIR / "quality.png", dpi=150)
    plt.close()
    print("Wrote quality.png")


def plot_pareto(evaluated, raw):
    """Pareto frontier: quality (cosine) vs latency (generate time)."""
    if not evaluated:
        return

    fig, ax = plt.subplots(figsize=(8, 6))

    points = []
    for s in evaluated:
        gt = s["generate_time_mean"]
        mc = s.get("meaning_cosine_mean")
        if mc is not None and not math.isnan(mc):
            points.append((s["name"], gt, mc))

    if len(points) < 2:
        ax.text(0.5, 0.5, "Need ≥2 evaluated candidates with cosine data",
                ha="center", va="center")
    else:
        # Sort by latency (x-axis)
        points.sort(key=lambda p: p[1])
        names = [p[0] for p in points]
        x = [p[1] for p in points]
        y = [p[2] for p in points]

        # Find Pareto frontier (minimize latency, maximize cosine)
        pareto_x = []
        pareto_y = []
        pareto_names = []
        max_cosine = 0
        for i in range(len(points)):
            if y[i] >= max_cosine:
                pareto_x.append(x[i])
                pareto_y.append(y[i])
                pareto_names.append(names[i])
                max_cosine = y[i]

        # Plot all points
        for i, (name, gx, mc) in enumerate(zip(names, x, y)):
            color = COLORS[i % len(COLORS)]
            is_pareto = name in pareto_names
            ax.scatter(gx, mc, c=color, s=120 if is_pareto else 80,
                      marker="*" if is_pareto else "o", zorder=5)
            ax.annotate(name, (gx, mc), textcoords="offset points",
                       xytext=(8, 5), fontsize=9)

        # Connect Pareto frontier
        if len(pareto_x) > 1:
            ax.plot(pareto_x, pareto_y, "k--", alpha=0.3, zorder=1)

    ax.set_xlabel("Generate Time (s) — lower is better")
    ax.set_ylabel("Meaning Preservation Cosine — higher is better")
    ax.set_title("Pareto Frontier: Quality vs Latency")
    ax.grid(True, alpha=0.3)

    plt.tight_layout()
    plt.savefig(PLOTS_DIR / "pareto_frontier.png", dpi=150)
    plt.close()
    print("Wrote pareto_frontier.png")


def plot_failure_modes(evaluated):
    """Stacked bar: stop reason + failure rates."""
    if not evaluated:
        return
    names = [s["name"] for s in evaluated]
    eos = [s["stop_eos_rate"] * 100 for s in evaluated]
    maxtok = [s["stop_maxTokens_rate"] * 100 for s in evaluated]
    loops = [s["decoder_loop_rate"] * 100 for s in evaluated]
    echos = [s["prompt_echo_rate"] * 100 for s in evaluated]

    fig, ax = plt.subplots(figsize=(10, 5))
    x = np.arange(len(names))
    width = 0.2

    ax.bar(x - 1.5*width, eos, width, label="EOS stop", color="#4CAF50", alpha=0.8)
    ax.bar(x - 0.5*width, maxtok, width, label="maxTokens stop", color="#FF9800", alpha=0.8)
    ax.bar(x + 0.5*width, loops, width, label="Decoder loop", color="#F44336", alpha=0.8)
    ax.bar(x + 1.5*width, echos, width, label="Prompt echo", color="#9C27B0", alpha=0.8)

    ax.set_ylabel("Rate (%)")
    ax.set_title("Failure Modes")
    ax.set_xticks(x)
    ax.set_xticklabels(names, rotation=45, ha="right")
    ax.legend()

    plt.tight_layout()
    plt.savefig(PLOTS_DIR / "failure_modes.png", dpi=150)
    plt.close()
    print("Wrote failure_modes.png")


def plot_verbosity(evaluated, raw):
    """Box plot: word count ratio per candidate."""
    if not evaluated:
        return

    fig, ax = plt.subplots(figsize=(10, 5))

    data = []
    labels = []
    for s in evaluated:
        candidate = next(c for c in raw["candidates"] if c["name"] == s["name"])
        ratios = [p["word_count_ratio"] for p in candidate["prompts"]]
        if ratios:
            data.append(ratios)
            labels.append(s["name"])

    if not data:
        ax.text(0.5, 0.5, "No data", ha="center", va="center")
    else:
        bp = ax.boxplot(data, tick_labels=labels, patch_artist=True, showfliers=True)
        for i, patch in enumerate(bp["boxes"]):
            patch.set_facecolor(COLORS[i % len(COLORS)])
            patch.set_alpha(0.6)

    ax.set_ylabel("Word Count Ratio (output/input)")
    ax.set_title("Verbosity: Output Length Relative to Input")
    ax.set_xticklabels(labels, rotation=45, ha="right")
    ax.axhline(y=1.0, color="gray", linestyle="--", alpha=0.5, label="ratio=1.0")
    ax.legend()

    plt.tight_layout()
    plt.savefig(PLOTS_DIR / "verbosity.png", dpi=150)
    plt.close()
    print("Wrote verbosity.png")


def plot_category_heatmap(evaluated):
    """Heatmap: per-category generate time."""
    if not evaluated:
        return

    # Collect all categories
    all_cats = set()
    for s in evaluated:
        all_cats.update(s.get("per_category", {}).keys())
    all_cats = sorted(all_cats)

    if not all_cats:
        return

    names = [s["name"] for s in evaluated]
    matrix = np.full((len(evaluated), len(all_cats)), np.nan)

    for i, s in enumerate(evaluated):
        for j, cat in enumerate(all_cats):
            vals = s.get("per_category", {}).get(cat)
            if vals and vals.get("generate_time_mean") is not None:
                matrix[i, j] = vals["generate_time_mean"]

    fig, ax = plt.subplots(figsize=(12, max(4, len(names) * 0.8)))
    im = ax.imshow(matrix, aspect="auto", cmap="YlOrRd")

    ax.set_xticks(np.arange(len(all_cats)))
    ax.set_yticks(np.arange(len(names)))
    ax.set_xticklabels(all_cats, rotation=45, ha="right")
    ax.set_yticklabels(names)

    # Add value annotations
    for i in range(len(names)):
        for j in range(len(all_cats)):
            if not np.isnan(matrix[i, j]):
                ax.text(j, i, f"{matrix[i, j]:.1f}",
                       ha="center", va="center", fontsize=8,
                       color="white" if matrix[i, j] > np.nanmax(matrix) * 0.6 else "black")

    plt.colorbar(im, ax=ax, label="Generate Time (s)")
    ax.set_title("Per-Category Generate Time Heatmap")

    plt.tight_layout()
    plt.savefig(PLOTS_DIR / "category_heatmap.png", dpi=150)
    plt.close()
    print("Wrote category_heatmap.png")


def plot_quality_vs_throughput(evaluated):
    """Scatter: quality (cosine) vs throughput (tokens/sec)."""
    if not evaluated:
        return

    fig, ax = plt.subplots(figsize=(8, 6))

    for i, s in enumerate(evaluated):
        mc = s.get("meaning_cosine_mean")
        tps = s.get("tokens_per_second_mean")
        if mc is not None and not math.isnan(mc) and tps:
            color = COLORS[i % len(COLORS)]
            ax.scatter(tps, mc, c=color, s=100, zorder=5)
            ax.annotate(s["name"], (tps, mc), textcoords="offset points",
                       xytext=(8, 5), fontsize=9)

    ax.set_xlabel("Tokens/sec — higher is better")
    ax.set_ylabel("Meaning Preservation Cosine — higher is better")
    ax.set_title("Quality vs Throughput")
    ax.grid(True, alpha=0.3)

    plt.tight_layout()
    plt.savefig(PLOTS_DIR / "quality_vs_throughput.png", dpi=150)
    plt.close()
    print("Wrote quality_vs_throughput.png")


def plot_memory_vs_latency(evaluated):
    """Scatter: peak RSS vs generate time."""
    if not evaluated:
        return

    fig, ax = plt.subplots(figsize=(8, 6))

    for i, s in enumerate(evaluated):
        rss = s.get("peak_rss_mb")
        gt = s.get("generate_time_mean")
        if rss and gt:
            color = COLORS[i % len(COLORS)]
            ax.scatter(rss, gt, c=color, s=100, zorder=5)
            ax.annotate(s["name"], (rss, gt), textcoords="offset points",
                       xytext=(8, 5), fontsize=9)

    ax.set_xlabel("Peak RSS (MB) — lower is better")
    ax.set_ylabel("Generate Time (s) — lower is better")
    ax.set_title("Memory vs Latency")
    ax.grid(True, alpha=0.3)

    plt.tight_layout()
    plt.savefig(PLOTS_DIR / "memory_vs_latency.png", dpi=150)
    plt.close()
    print("Wrote memory_vs_latency.png")


def main():
    PLOTS_DIR.mkdir(parents=True, exist_ok=True)
    summary, raw = load_data()
    evaluated = get_evaluated(summary)

    if not evaluated:
        print("No evaluated candidates to plot.")
        return

    print(f"Plotting {len(evaluated)} evaluated candidates...")

    plot_latency(evaluated, raw)
    plot_throughput(evaluated)
    plot_memory(evaluated)
    plot_quality(evaluated, raw)
    plot_pareto(evaluated, raw)
    plot_failure_modes(evaluated)
    plot_verbosity(evaluated, raw)
    plot_category_heatmap(evaluated)
    plot_quality_vs_throughput(evaluated)
    plot_memory_vs_latency(evaluated)

    print(f"\nAll plots written to {PLOTS_DIR}")


if __name__ == "__main__":
    main()