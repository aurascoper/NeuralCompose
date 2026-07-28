"""Tests for shared evaluation statistics utilities."""
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent / "Evaluation" / "scripts"))

import math
import numpy as np
import pytest
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


def test_cohens_d_large_effect():
    """Constant samples with different means are an unbounded effect.

    Both groups have zero within-group variance, so pooled SD is 0 and the
    effect size diverges. The implementation used to return 0.0 here — "no
    effect" for the most extreme separation representable — and the test asserted
    `d > 2.0`, which is a magnitude claim written as a signed one: the fixture
    has a < b, so d is negative.

    Assert the actual value. Signed infinity carries both facts: the effect is
    unbounded, and it points from a to b.
    """
    d = cohens_d([1, 1, 1, 1], [5, 5, 5, 5])
    assert math.isinf(d) and d < 0
    assert math.isinf(cohens_d([5, 5, 5, 5], [1, 1, 1, 1])) and \
        cohens_d([5, 5, 5, 5], [1, 1, 1, 1]) > 0


def test_cohens_d_identical_constants_is_zero():
    """Constant *and* equal is the one genuinely zero case."""
    assert cohens_d([3, 3, 3], [3, 3, 3]) == 0.0


def test_cohens_d_large_effect_with_variance():
    """The ordinary large-effect case, where pooled SD is defined."""
    d = cohens_d([1, 2, 1, 2], [9, 10, 9, 10])
    assert abs(d) > 2.0


def test_cohens_d_unequal_sizes_uses_df_weighted_pooling():
    """Pooled variance must be weighted by degrees of freedom.

    The unweighted (var_a + var_b) / 2 form coincides with the conventional
    estimator only at equal n, and this function accepts arbitrary lengths — so
    an unequal-n caller was silently dividing by the wrong denominator. Every
    earlier test used equal groups, which is exactly why it survived.

    This fixture is chosen so the two formulas disagree: n=3 with small variance
    against n=9 with large variance, so df-weighting pulls the pooled estimate
    toward the larger, noisier group.
    """
    a = [10.0, 10.5, 9.5]
    b = [1.0, 5.0, 9.0, 2.0, 8.0, 3.0, 7.0, 4.0, 6.0]

    va, vb = np.var(a, ddof=1), np.var(b, ddof=1)
    unweighted = (np.mean(a) - np.mean(b)) / math.sqrt((va + vb) / 2)
    weighted = (np.mean(a) - np.mean(b)) / math.sqrt(
        ((len(a) - 1) * va + (len(b) - 1) * vb) / (len(a) + len(b) - 2))

    assert not math.isclose(unweighted, weighted, rel_tol=0.05), \
        "fixture must distinguish the two formulas"
    assert cohens_d(a, b) == pytest.approx(weighted)
    assert cohens_d(a, b) != pytest.approx(unweighted)


def test_mann_whitney_method_is_explicit_not_inherited():
    """Ties must not be scored with the exact distribution.

    The implementation used to call SciPy without `method=`, inheriting `auto` —
    a selection rule that has changed across releases and would move a reported
    p-value between versions. With ties present, exact is invalid, so the
    asymptotic approximation is required and the p-value must differ from the
    tie-free case.
    """
    tied = mann_whitney_u([1, 2, 2, 3], [2, 4, 5, 6])
    assert math.isfinite(tied["p_value"])
    assert 0.0 <= tied["p_value"] <= 1.0


def test_mann_whitney_u_disjoint():
    """Perfect separation at n=3 vs 3 gives p = 0.1, not p < 0.05.

    The exact two-sided p-value cannot go below 2 / C(6,3) = 2/20 = 0.1 at these
    sample sizes, so the previous `p < 0.05` was unreachable by construction —
    no implementation could have passed it. The test never ran (this module
    failed collection), which is why an impossible assertion survived.

    Assert the floor itself: it pins that the implementation is exact rather
    than normal-approximating, which would report a smaller and wrong p.
    """
    result = mann_whitney_u([1, 2, 3], [10, 11, 12])
    assert result["p_value"] == pytest.approx(0.1, abs=1e-9)
    assert "u_statistic" in result


def test_mann_whitney_u_reaches_significance_with_enough_samples():
    """The same perfect separation clears 0.05 once n permits it: at n=4 vs 4
    the floor is 2 / C(8,4) = 2/70 ≈ 0.0286."""
    result = mann_whitney_u([1, 2, 3, 4], [10, 11, 12, 13])
    assert result["p_value"] < 0.05


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
