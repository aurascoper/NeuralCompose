"""Tests for embedding-space analysis functions."""
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent / "Evaluation" / "scripts"))

import numpy as np
from embedding_space_analysis import cka, svcca, procrustes_alignment, neighborhood_overlap


def test_cka_identical():
    np.random.seed(42)
    X = np.random.randn(50, 128)
    score = cka(X, X)
    assert abs(score - 1.0) < 1e-3


def test_cka_independent():
    np.random.seed(42)
    X = np.random.randn(50, 128)
    Y = np.random.randn(50, 256)
    score = cka(X, Y)
    assert abs(score) < 0.3


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
