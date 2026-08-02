#!/usr/bin/env python3
"""Executes WorldModel/frame_diagnostic.py's self-test in CI.

Before this file existed, that self-test could not run here: frame_diagnostic
did a bare `import torch`, and this job installs numpy/scipy/pandas but no
torch. Its own docstring said "run it before trusting any number this produces"
with no mechanism behind it -- a promise, not evidence.

frame_diagnostic now falls back to WorldModel/_tensor_shim.py, so the four
polarities and the 50-case invariant sweep run on every push.

WHAT A PASS HERE DOES AND DOES NOT MEAN

Does:     the algorithm is correct -- an identical pair reports no mismatch, a
          rotated pair reports mismatch that Procrustes absorbs, a per-dimension
          scaled pair reports mismatch it does NOT absorb, a translated pair
          reports nan rather than dividing noise by noise, and the residual
          ratio never exceeds 1 across 50 mixed perturbations.
Does not: discharge running against real torch. The shim may differ in SVD sign
          conventions and float32-vs-float64 accumulation. Production numbers
          still require `python3 WorldModel/frame_diagnostic.py` under torch.
"""

from __future__ import annotations

import math
import sys
import unittest
from pathlib import Path


REPOSITORY_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPOSITORY_ROOT / "WorldModel"))

import frame_diagnostic  # noqa: E402


class FrameDiagnosticSelfTest(unittest.TestCase):
    def test_self_test_passes(self) -> None:
        """The four polarities plus the invariant sweep, unmodified."""
        frame_diagnostic._self_test()


class RotationMagnitudeTests(unittest.TestCase):
    """Pins the one new mathematical claim in the module docstring.

    `rotation_from_identity` is documented as ||R - I||_F / (2*sqrt(d)), which
    equals sin(theta/2) for a rotation by a common angle theta. That is a
    checkable identity, so check it rather than asserting it in prose.
    """

    def _gap(self, theta: float, d: int = 8) -> float:
        torch = frame_diagnostic.torch
        # Block-diagonal rotation by `theta` in every 2-plane.
        rows = []
        for i in range(d):
            row = [0.0] * d
            block, within = divmod(i, 2)
            j = block * 2
            if within == 0:
                row[j], row[j + 1] = math.cos(theta), -math.sin(theta)
            else:
                row[j], row[j + 1] = math.sin(theta), math.cos(theta)
            rows.append(row)
        # torch.Tensor(nested_list) constructs in both real torch and the shim.
        gap = float(torch.linalg.norm(torch.Tensor(rows) - torch.eye(d)))
        return gap / (2.0 * math.sqrt(d))

    def test_equals_sin_half_theta(self) -> None:
        for theta in (0.1, 0.5, 1.0, 2.0, math.pi):
            with self.subTest(theta=theta):
                self.assertAlmostEqual(self._gap(theta), math.sin(theta / 2), places=6)

    def test_identity_is_zero_and_negative_identity_is_one(self) -> None:
        self.assertAlmostEqual(self._gap(0.0), 0.0, places=9)
        self.assertAlmostEqual(self._gap(math.pi), 1.0, places=6)


if __name__ == "__main__":
    unittest.main(verbosity=1)
