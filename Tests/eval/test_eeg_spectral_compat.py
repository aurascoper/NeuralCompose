"""Tests for eeg_spectral.py's NumPy integrator resolution.

The resolver has to work on both NumPy 1.x (`trapz` only) and NumPy 2.x
(`trapezoid` only). Injecting fake namespaces covers both API shapes from a
single interpreter, so neither version can regress unnoticed just because the
calibration venv happens to pin the other one.
"""
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent / "Scripts"))

import numpy as np

from eeg_spectral import _resolve_trapezoid, band_power


class NumPy1:
    """numpy<2.0: `trapz` exists, `trapezoid` does not."""

    @staticmethod
    def trapz(*args, **kwargs):
        return "trapz"


class NumPy2:
    """numpy>=2.0: `trapezoid` exists and `trapz` was removed. Touching `trapz`
    raises, exactly as the real module's __getattr__ does."""

    @staticmethod
    def trapezoid(*args, **kwargs):
        return "trapezoid"

    def __getattr__(self, name):
        raise AttributeError(f"module 'numpy' has no attribute {name!r}")


class ResolveTrapezoidTests(unittest.TestCase):
    def test_prefers_trapezoid_when_present(self):
        self.assertEqual(_resolve_trapezoid(NumPy2())(), "trapezoid")

    def test_falls_back_to_trapz_when_trapezoid_absent(self):
        self.assertEqual(_resolve_trapezoid(NumPy1())(), "trapz")

    def test_does_not_touch_trapz_when_trapezoid_exists(self):
        """The regression: a `getattr(np, "trapezoid", getattr(np, "trapz"))`
        default is evaluated eagerly, so it raises on numpy 2.x before the
        preferred name is ever consulted."""

        class TrapzIsFatal(NumPy2):
            @property
            def trapz(self):
                raise AssertionError("resolver must not evaluate trapz")

        self.assertEqual(_resolve_trapezoid(TrapzIsFatal())(), "trapezoid")

    def test_resolves_against_the_installed_numpy(self):
        self.assertTrue(callable(_resolve_trapezoid(np)))


class BandPowerTests(unittest.TestCase):
    def test_integrates_a_flat_band(self):
        freqs = np.linspace(0.0, 10.0, 101)
        psd = np.ones_like(freqs)
        self.assertAlmostEqual(band_power(freqs, psd, (2.0, 6.0)), 4.0, places=6)

    def test_band_outside_the_spectrum_is_zero(self):
        freqs = np.linspace(0.0, 10.0, 101)
        self.assertEqual(band_power(freqs, np.ones_like(freqs), (50.0, 60.0)), 0.0)


if __name__ == "__main__":
    unittest.main()
