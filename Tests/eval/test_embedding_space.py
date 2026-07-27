"""Tests for embedding-space analysis functions."""
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent / "Evaluation" / "scripts"))

import numpy as np
from embedding_space_analysis import (
    cka,
    svcca,
    procrustes_alignment,
    orthogonal_procrustes_alignment,
    neighborhood_overlap,
)


def test_cka_identical():
    np.random.seed(42)
    X = np.random.randn(50, 128)
    score = cka(X, X)
    assert abs(score - 1.0) < 1e-3


def test_cka_independent_is_small_when_samples_exceed_dimensions():
    rng = np.random.default_rng(42)
    X = rng.standard_normal((500, 16))
    Y = rng.standard_normal((500, 32))
    assert cka(X, Y) < 0.1


def test_biased_cka_null_is_inflated_when_dimensions_exceed_samples():
    # Characterizes the selected biased estimator; NOT evidence that these
    # representations are genuinely similar. The previous expectation
    # (< 0.3 at n=50, d=128/256) assumed an unbiased estimator or n >> d.
    rng = np.random.default_rng(42)
    X = rng.standard_normal((50, 128))
    Y = rng.standard_normal((50, 256))
    assert cka(X, Y) > 0.5


def test_svcca_identical():
    score = svcca(np.random.randn(50, 128), np.random.randn(50, 128).copy())
    assert 0.0 <= score <= 1.0


def test_procrustes_alignment_identical():
    X = np.random.randn(20, 64)
    result = procrustes_alignment(X, X)
    assert result["disparity"] < 1e-6


def test_neighborhood_overlap_identical():
    X = np.random.randn(30, 64)
    overlap = neighborhood_overlap(X, X, top_k=5)
    assert overlap == 1.0


def test_orthogonal_procrustes_alignment_identical():
    X = np.random.randn(20, 64)
    result = orthogonal_procrustes_alignment(X, X)
    assert result["disparity"] < 1e-6


def test_orthogonal_procrustes_alignment_detects_scale_mismatch():
    # A pure scale mismatch is invisible to scaled Procrustes (it rescales
    # both inputs to unit norm first) but must show up here, since this
    # variant deliberately skips that rescale -- this is the entire point
    # of adding the metric (methodology-review_v1.md Pillar A).
    np.random.seed(0)
    X = np.random.randn(20, 64)
    R = np.linalg.qr(np.random.randn(64, 64))[0]
    Y = (X @ R) * 3.0
    scaled = procrustes_alignment(X, Y)
    orthogonal = orthogonal_procrustes_alignment(X, Y)
    assert scaled["disparity"] < 1e-6
    # For a pure scale factor c with the rotation otherwise recovered
    # exactly, disparity = (c-1)^2 / c^2 regardless of the data -- for
    # c=3.0 that's 4/9 ~= 0.444, deterministic and seed-independent.
    assert orthogonal["disparity"] > 0.3


def test_orthogonal_procrustes_alignment_row_count_mismatch_no_crash():
    X = np.random.randn(20, 64)
    Y = np.random.randn(15, 64)
    result = orthogonal_procrustes_alignment(X, Y)
    assert result["n_samples"] == 15


def test_procrustes_alignment_row_count_mismatch_no_crash():
    X = np.random.randn(20, 64)
    Y = np.random.randn(15, 64)
    result = procrustes_alignment(X, Y)
    assert result["n_samples"] == 15
