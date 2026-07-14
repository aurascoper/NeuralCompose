#!/usr/bin/env python3
"""
Generate plots for the embedding benchmark.

Reads:  Evaluation/results/embeddings/leaderboard.json
Writes: Evaluation/results/embeddings/plots/

Plot types:
  1. Quality vs Latency scatter
  2. Stability vs Latency scatter
  3. Memory vs Quality scatter
  4. Stability by variant type (grouped bar)
  5. Pareto frontier (quality vs latency)
  6. Overall score bar chart
  7. Radar chart (top 5 models across metrics)
  8. Runtime comparison (where same model has multiple runtimes)
  9. Embedding dimension vs latency
  10. Throughput vs memory
"""
import json
import sys
from pathlib import Path

import numpy as np
import matplotlib
matplotlib.use('Agg')  # Non-interactive backend
import matplotlib.pyplot as plt

REPO_ROOT = Path(__file__).resolve().parent.parent.parent
RESULTS_DIR = REPO_ROOT / "Evaluation" / "results" / "embeddings"
PLOTS_DIR = RESULTS_DIR / "plots"
LEADERBOARD_PATH = RESULTS_DIR / "leaderboard.json"


def load_data():
    if not LEADERBOARD_PATH.exists():
        print("ERROR: leaderboard.json not found")
        sys.exit(1)
    with open(LEADERBOARD_PATH) as f:
        return json.load(f)


def get_color(name):
    """Deterministic color per model name."""
    colors = plt.cm.tab20(np.linspace(0, 1, 20))
    h = hash(name) % 20
    return colors[h]


def plot_quality_vs_latency(candidates, path):
    fig, ax = plt.subplots(figsize=(10, 7))
    for c in candidates:
        if c.get("failure_rate", 0) >= 1:
            continue
        ax.scatter(c.get("cold_load_time", 0), c.get("quality_score", 0),
                   s=80, alpha=0.7, label=f"{c['name']} ({c['runtime']})",
                   color=get_color(c['name']))
        ax.annotate(c['name'].replace('-', '\n'),
                    (c.get("cold_load_time", 0), c.get("quality_score", 0)),
                    fontsize=7, ha='center', va='bottom')
    ax.set_xlabel('Cold Load Time (s)')
    ax.set_ylabel('Quality Score')
    ax.set_title('Quality vs Latency')
    ax.legend(fontsize=6, loc='best', ncol=2)
    ax.grid(True, alpha=0.3)
    plt.tight_layout()
    plt.savefig(path, dpi=150)
    plt.close()


def plot_stability_vs_latency(candidates, path):
    fig, ax = plt.subplots(figsize=(10, 7))
    for c in candidates:
        if c.get("failure_rate", 0) >= 1:
            continue
        ax.scatter(c.get("cold_load_time", 0), c.get("stability_mean", 0),
                   s=80, alpha=0.7, label=f"{c['name']} ({c['runtime']})",
                   color=get_color(c['name']))
        ax.annotate(c['name'].replace('-', '\n'),
                    (c.get("cold_load_time", 0), c.get("stability_mean", 0)),
                    fontsize=7, ha='center', va='bottom')
    ax.set_xlabel('Cold Load Time (s)')
    ax.set_ylabel('Stability Mean (cosine)')
    ax.set_title('ASR Robustness vs Latency')
    ax.legend(fontsize=6, loc='best', ncol=2)
    ax.grid(True, alpha=0.3)
    plt.tight_layout()
    plt.savefig(path, dpi=150)
    plt.close()


def plot_memory_vs_quality(candidates, path):
    fig, ax = plt.subplots(figsize=(10, 7))
    for c in candidates:
        if c.get("failure_rate", 0) >= 1:
            continue
        ax.scatter(c.get("peak_rss_mb", 0), c.get("quality_score", 0),
                   s=80, alpha=0.7, label=f"{c['name']} ({c['runtime']})",
                   color=get_color(c['name']))
        ax.annotate(c['name'].replace('-', '\n'),
                    (c.get("peak_rss_mb", 0), c.get("quality_score", 0)),
                    fontsize=7, ha='center', va='bottom')
    ax.set_xlabel('Peak RSS (MB)')
    ax.set_ylabel('Quality Score')
    ax.set_title('Memory vs Quality')
    ax.legend(fontsize=6, loc='best', ncol=2)
    ax.grid(True, alpha=0.3)
    plt.tight_layout()
    plt.savefig(path, dpi=150)
    plt.close()


def plot_stability_by_type(candidates, path):
    variant_types = ["asr", "typo", "hesitation", "filler",
                     "punctuation", "capitalization", "no_punctuation", "doubled_word"]

    valid = [c for c in candidates if c.get("failure_rate", 0) < 1]
    if not valid:
        return

    fig, ax = plt.subplots(figsize=(14, 7))
    x = np.arange(len(variant_types))
    width = 0.8 / max(len(valid), 1)

    for i, c in enumerate(valid):
        st = c.get("stability_by_type", {})
        values = [st.get(vt, {}).get("mean", 0) for vt in variant_types]
        ax.bar(x + i * width, values, width, alpha=0.7,
               label=f"{c['name']} ({c['runtime']})", color=get_color(c['name']))

    ax.set_xlabel('Variant Type')
    ax.set_ylabel('Mean Cosine Similarity')
    ax.set_title('Embedding Stability by Variant Type')
    ax.set_xticks(x + width * len(valid) / 2)
    ax.set_xticklabels(variant_types, rotation=30, ha='right')
    ax.legend(fontsize=5, loc='best', ncol=3)
    ax.grid(True, alpha=0.3, axis='y')
    ax.set_ylim(0, 1.05)
    plt.tight_layout()
    plt.savefig(path, dpi=150)
    plt.close()


def plot_pareto(candidates, pareto_frontier, path):
    fig, ax = plt.subplots(figsize=(10, 7))
    valid = [c for c in candidates if c.get("failure_rate", 0) < 1]

    for c in valid:
        label = f"{c['name']} ({c['runtime']})"
        is_pareto = label in pareto_frontier
        marker = '*' if is_pareto else 'o'
        size = 150 if is_pareto else 60
        ax.scatter(c.get("cold_load_time", 0), c.get("quality_score", 0),
                   s=size, alpha=0.7, marker=marker,
                   color=get_color(c['name']),
                   edgecolors='red' if is_pareto else 'none', linewidths=1.5)
        if is_pareto:
            ax.annotate(label, (c.get("cold_load_time", 0), c.get("quality_score", 0)),
                        fontsize=7, fontweight='bold', ha='center', va='bottom')

    ax.set_xlabel('Cold Load Time (s)')
    ax.set_ylabel('Quality Score')
    ax.set_title('Pareto Frontier (Quality vs Latency)')
    ax.grid(True, alpha=0.3)
    plt.tight_layout()
    plt.savefig(path, dpi=150)
    plt.close()


def plot_score_bar(candidates, path):
    valid = sorted([c for c in candidates if c.get("failure_rate", 0) < 1],
                   key=lambda c: c.get("overall_score", 0))

    fig, ax = plt.subplots(figsize=(12, 8))
    names = [f"{c['name']} ({c['runtime']})" for c in valid]
    scores = [c.get("overall_score", 0) for c in valid]
    colors = [get_color(c['name']) for c in valid]

    bars = ax.barh(names, scores, color=colors, alpha=0.7)
    for bar, score in zip(bars, scores):
        ax.text(bar.get_width() + 0.002, bar.get_y() + bar.get_height()/2,
                f'{score:.3f}', va='center', fontsize=7)

    ax.set_xlabel('Overall Score')
    ax.set_title('Overall Embedding Benchmark Scores')
    ax.grid(True, alpha=0.3, axis='x')
    plt.tight_layout()
    plt.savefig(path, dpi=150)
    plt.close()


def plot_radar(candidates, path):
    """Radar chart for top 5 models."""
    valid = sorted([c for c in candidates if c.get("failure_rate", 0) < 1],
                   key=lambda c: -c.get("overall_score", 0))[:5]

    if len(valid) < 3:
        return

    metrics = ["norm_quality", "norm_stability", "norm_latency",
               "norm_throughput", "norm_memory", "norm_consistency"]
    metric_labels = ["Quality", "Stability", "Latency", "Throughput", "Memory", "Consistency"]

    angles = np.linspace(0, 2 * np.pi, len(metrics), endpoint=False).tolist()
    angles += angles[:1]

    fig, ax = plt.subplots(figsize=(8, 8), subplot_kw=dict(polar=True))

    for c in valid:
        values = [c.get(m, 0) for m in metrics]
        values += values[:1]
        ax.plot(angles, values, 'o-', linewidth=1.5, markersize=4,
                label=f"{c['name']} ({c['runtime']})", alpha=0.7)
        ax.fill(angles, values, alpha=0.08)

    ax.set_thetagrids(angles[:-1], metric_labels)
    ax.set_title('Top 5 Models — Normalized Metrics')
    ax.legend(fontsize=6, loc='upper right', bbox_to_anchor=(1.3, 1.1))
    ax.set_ylim(0, 1.05)
    plt.tight_layout()
    plt.savefig(path, dpi=150)
    plt.close()


def plot_runtime_comparison(candidates, path):
    """Compare runtimes for models tested with multiple runtimes."""
    from collections import defaultdict
    by_name = defaultdict(list)
    for c in candidates:
        if c.get("failure_rate", 0) < 1:
            by_name[c["name"]].append(c)

    multi = {name: models for name, models in by_name.items() if len(models) > 1}
    if not multi:
        return

    fig, axes = plt.subplots(1, 3, figsize=(15, 5))

    for ax_idx, (metric, title) in enumerate([
        ("cold_load_time", "Cold Load (s)"),
        ("embeddings_per_second", "Throughput (emb/s)"),
        ("peak_rss_mb", "Memory (MB)"),
    ]):
        ax = axes[ax_idx]
        names = list(multi.keys())
        x = np.arange(len(names))
        width = 0.8 / max(len(models) for models in multi.values())

        for name_idx, (name, models) in enumerate(multi.items()):
            for rt_idx, c in enumerate(models):
                ax.bar(x[name_idx] + rt_idx * width,
                       c.get(metric, 0), width,
                       label=c['runtime'] if name_idx == 0 else "",
                       alpha=0.7)

        ax.set_xticks(x)
        ax.set_xticklabels([n.replace('-', '\n') for n in names], fontsize=7)
        ax.set_title(title)
        ax.legend(fontsize=7)
        ax.grid(True, alpha=0.3, axis='y')

    plt.suptitle('Runtime Comparison (Same Model, Different Runtime)')
    plt.tight_layout()
    plt.savefig(path, dpi=150)
    plt.close()


def plot_dim_vs_latency(candidates, path):
    valid = [c for c in candidates if c.get("failure_rate", 0) < 1]
    if not valid:
        return

    fig, ax = plt.subplots(figsize=(10, 7))
    for c in valid:
        ax.scatter(c.get("dimension", 0), c.get("cold_load_time", 0),
                   s=80, alpha=0.7, color=get_color(c['name']))
        ax.annotate(c['name'].replace('-', '\n'),
                    (c.get("dimension", 0), c.get("cold_load_time", 0)),
                    fontsize=7, ha='center', va='bottom')
    ax.set_xlabel('Embedding Dimension')
    ax.set_ylabel('Cold Load Time (s)')
    ax.set_title('Embedding Dimension vs Latency')
    ax.grid(True, alpha=0.3)
    plt.tight_layout()
    plt.savefig(path, dpi=150)
    plt.close()


def plot_throughput_vs_memory(candidates, path):
    valid = [c for c in candidates if c.get("failure_rate", 0) < 1]
    if not valid:
        return

    fig, ax = plt.subplots(figsize=(10, 7))
    for c in valid:
        ax.scatter(c.get("peak_rss_mb", 0), c.get("embeddings_per_second", 0),
                   s=80, alpha=0.7, color=get_color(c['name']))
        ax.annotate(c['name'].replace('-', '\n'),
                    (c.get("peak_rss_mb", 0), c.get("embeddings_per_second", 0)),
                    fontsize=7, ha='center', va='bottom')
    ax.set_xlabel('Peak RSS (MB)')
    ax.set_ylabel('Embeddings per Second')
    ax.set_title('Throughput vs Memory')
    ax.grid(True, alpha=0.3)
    plt.tight_layout()
    plt.savefig(path, dpi=150)
    plt.close()


def main():
    leaderboard = load_data()
    candidates = leaderboard.get("candidates", [])
    pareto = leaderboard.get("pareto_frontier", [])

    PLOTS_DIR.mkdir(parents=True, exist_ok=True)

    plots = [
        ("01_quality_vs_latency.png", lambda p: plot_quality_vs_latency(candidates, p)),
        ("02_stability_vs_latency.png", lambda p: plot_stability_vs_latency(candidates, p)),
        ("03_memory_vs_quality.png", lambda p: plot_memory_vs_quality(candidates, p)),
        ("04_stability_by_type.png", lambda p: plot_stability_by_type(candidates, p)),
        ("05_pareto_frontier.png", lambda p: plot_pareto(candidates, pareto, p)),
        ("06_score_bar.png", lambda p: plot_score_bar(candidates, p)),
        ("07_radar_top5.png", lambda p: plot_radar(candidates, p)),
        ("08_runtime_comparison.png", lambda p: plot_runtime_comparison(candidates, p)),
        ("09_dim_vs_latency.png", lambda p: plot_dim_vs_latency(candidates, p)),
        ("10_throughput_vs_memory.png", lambda p: plot_throughput_vs_memory(candidates, p)),
    ]

    print(f"Generating {len(plots)} plots...")
    for name, plot_fn in plots:
        path = PLOTS_DIR / name
        try:
            plot_fn(path)
            print(f"  {name}")
        except Exception as e:
            print(f"  {name} — SKIPPED ({e})")

    print(f"\nPlots written to: {PLOTS_DIR}")


if __name__ == "__main__":
    main()