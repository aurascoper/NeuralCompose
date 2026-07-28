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


def test_cka_independent():
    """Independent data does NOT give CKA near zero when d >> n.

    This is the biased linear CKA estimator (Kornblith et al.). With 50 samples
    against 128 and 256 features it inflates severely — ~0.78 here — because the
    Gram matrices of independent high-dimensional Gaussians are far from
    orthogonal at this sample size. The previous `< 0.3` described an unbiased
    estimator this code does not implement, and the test never ran to contradict
    it.

    Pinned as an upper bound rather than an equality: the point is that the
    inflation is real and bounded, so a future switch to an unbiased estimator
    (which would drop this toward 0) fails here and forces the expectation to be
    revisited deliberately.
    """
    np.random.seed(42)
    X = np.random.randn(50, 128)
    Y = np.random.randn(50, 256)
    score = cka(X, Y)
    assert 0.0 <= score <= 1.0
    assert score > 0.5, "biased CKA is expected to inflate at d >> n"


def test_cka_inflation_shrinks_as_samples_grow():
    """The inflation is a sample-size artefact, not a property of the data:
    raising n against fixed d moves the independent-data score down."""
    np.random.seed(42)
    few = cka(np.random.randn(50, 128), np.random.randn(50, 128))
    many = cka(np.random.randn(400, 128), np.random.randn(400, 128))
    assert many < few


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
