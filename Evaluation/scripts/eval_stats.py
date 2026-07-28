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
    """Mann-Whitney U test."""
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
