"""Tests for shared evaluation statistics utilities."""
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent / "Evaluation" / "scripts"))

import numpy as np
from eval_stats import bootstrap_ci, cohens_d, mann_whitney_u, bonferroni_correct, pareto_frontier, min_max_normalize


def test_bootstrap_ci_known_data():
    data = [1.0, 2.0, 3.0, 4.0, 5.0]
    lo, hi, n = bootstrap_ci(data, confidence=0.95, n_boot=1000)
    assert n == 5
    assert lo < 3.0 < hi
    assert lo >= 1.5 and hi <= 4.5  # wide enough for 5 samples


def test_bootstrap_ci_empty():
    lo, hi, n = bootstrap_ci([])
    assert n == 0
    assert np.isnan(lo) and np.isnan(hi)


def test_cohens_d_identical():
    d = cohens_d([1, 2, 3], [1, 2, 3])
    assert d == 0.0


def test_cohens_d_identical_constant_groups_are_zero():
    assert cohens_d([1, 1, 1, 1], [1, 1, 1, 1]) == 0.0


def test_cohens_d_separated_constant_groups_are_undefined():
    # Zero pooled variance with separated means: d is unbounded, not absent.
    # Returning 0.0 here would rank total separation as "no effect".
    assert np.isnan(cohens_d([1, 1, 1, 1], [5, 5, 5, 5]))


def test_cohens_d_large_nondegenerate_effect():
    d = cohens_d([0.9, 1.0, 1.1, 1.0], [4.9, 5.0, 5.1, 5.0])
    assert abs(d) > 2.0


def test_mann_whitney_u_disjoint():
    result = mann_whitney_u([1, 2, 3], [10, 11, 12])
    assert result["p_value"] < 0.05
    assert "u_statistic" in result


def test_bonferroni_correct():
    pvals = [0.01, 0.04, 0.03]
    corrected = bonferroni_correct(pvals)
    assert all(c <= 1.0 for c in corrected)
    assert corrected[0] == 0.03  # 0.01 * 3


def test_pareto_frontier():
    candidates = [
        {"name": "A", "latency": 1.0, "quality": 0.5},
        {"name": "B", "latency": 2.0, "quality": 0.8},
        {"name": "C", "latency": 3.0, "quality": 0.7},  # dominated by B
    ]
    frontier = pareto_frontier(candidates, "latency", "quality")
    assert "A" in frontier
    assert "B" in frontier
    assert "C" not in frontier


def test_min_max_normalize():
    values = [1, 2, 3, 4, 5]
    normed = min_max_normalize(values)
    assert abs(normed[0] - 0.0) < 1e-9
    assert abs(normed[-1] - 1.0) < 1e-9
