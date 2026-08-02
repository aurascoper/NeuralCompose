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


class Float32DegeneracyTests(unittest.TestCase):
    """Regression for a failure the pure-Python shim could not surface.

    The degeneracy guard was originally a fixed relative floor, `_REL_EPS =
    1e-8`. Under the shim that looked adequate, because its float64 centering
    of a pure translation cancelled to ~1e-14 so the floor fired. Under real
    torch (float32 by default) the same case leaves before = 6.6e-06 against
    scale = 91.8, the floor sat at 9.2e-07 and never fired, and the ratio came
    out 4.48 -- an arithmetically impossible value reported as a finding.

    The constant had been calibrated to an artifact of the test harness. The
    guard is now the guaranteed invariant itself (after <= before, since R = I
    is always feasible) plus a dtype-aware sqrt(finfo.eps) floor.

    Skips where torch is absent, and says so, rather than passing vacuously
    under the shim -- which is the exact failure mode being regressed.
    """

    def setUp(self) -> None:
        if frame_diagnostic.torch.__name__ == "_tensor_shim":
            self.skipTest("needs real torch: the shim is float64 and cannot "
                          "reproduce the float32 case this regresses")

    def test_float32_pure_translation_reports_nan(self) -> None:
        torch = frame_diagnostic.torch
        torch.manual_seed(0)
        base = torch.randn(64, 32)
        offset = torch.randn(1, 32) * 3.0

        def encode(states, use_target: bool = False):
            z = states[0]
            return z + offset if use_target else z

        out = frame_diagnostic.frame_diagnostic(encode, [base], [base + 0.05])
        r = out["procrustes_residual_ratio"]
        self.assertNotEqual(r, r, f"float32 pure translation must report nan, got {r}")
        self.assertGreater(out["centroid_gap"], 1.0,
                           "the translation must still be visible in centroid_gap")

    def test_invariant_holds_in_float32_across_perturbations(self) -> None:
        torch = frame_diagnostic.torch
        torch.manual_seed(1)
        base = torch.randn(64, 32)
        for i in range(25):
            g = torch.Generator().manual_seed(500 + i)
            pert = torch.randn(32, 32, generator=g) * (0.01 * (1 + i % 10))
            out = frame_diagnostic.frame_diagnostic(
                lambda s, use_target=False, p=pert: s[0] + s[0] @ p if use_target else s[0],
                [base], [base + 0.05])
            r = out["procrustes_residual_ratio"]
            self.assertTrue(r != r or r <= 1.0 + 1e-6,
                            f"perturbation {i}: residual ratio {r} > 1 is impossible")


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
