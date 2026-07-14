"""
Shared statistical utilities for NeuralCompose evaluation scripts.

Consolidates bootstrap_ci, cohens_d, mann_whitney_u, bonferroni_correct,
pareto_frontier, and min_max_normalize — previously duplicated in
embedding_analyze.py and statistical_analysis.py.
"""
import math
from typing import Any

import numpy as np
from scipy import stats as sp_stats


def bootstrap_ci(data, confidence=0.95, n_boot=10000):
    """Bootstrap confidence interval for the mean.

    Returns: (lo, hi, n)
    """
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
    """Cohen's d effect size between two samples."""
    a, b = np.array(a, dtype=float), np.array(b, dtype=float)
    if len(a) < 2 or len(b) < 2:
        return float("nan")
    pooled_std = math.sqrt((a.var(ddof=1) + b.var(ddof=1)) / 2)
    if pooled_std == 0:
        return 0.0
    return float((a.mean() - b.mean()) / pooled_std)


def mann_whitney_u(a, b):
    """Mann-Whitney U test."""
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
    """Bonferroni multiple comparison correction."""
    p_values = np.array(p_values)
    n = len(p_values)
    return np.minimum(p_values * n, 1.0).tolist()


def pareto_frontier(candidates: list[dict], cost_key: str, benefit_key: str) -> list[str]:
    """Identify Pareto-optimal candidates.

    cost_key: lower is better (e.g. latency).
    benefit_key: higher is better (e.g. quality).
    """
    if not candidates:
        return []
    names = [c["name"] for c in candidates]
    costs = [c.get(cost_key, float("inf")) for c in candidates]
    benefits = [c.get(benefit_key, 0) for c in candidates]
    frontier = []
    for i, name in enumerate(names):
        dominated = False
        for j, other in enumerate(names):
            if i == j:
                continue
            if (costs[j] <= costs[i] and benefits[j] >= benefits[i]
                    and (costs[j] < costs[i] or benefits[j] > benefits[i])):
                dominated = True
                break
        if not dominated:
            frontier.append(name)
    return frontier


def min_max_normalize(values):
    """Min-max normalize a list to [0, 1]."""
    arr = np.array(values, dtype=float)
    lo, hi = arr.min(), arr.max()
    if hi - lo < 1e-12:
        return np.zeros_like(arr).tolist()
    return ((arr - lo) / (hi - lo)).tolist()
