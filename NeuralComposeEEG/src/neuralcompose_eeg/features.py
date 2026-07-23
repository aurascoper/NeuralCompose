"""Deterministic signal features for the preregistered M0 reality check."""

from __future__ import annotations

import numpy as np
from scipy import signal

from .contracts import TARGET_SAMPLE_RATE_HZ
from .dataset import QUALITY_NAMES


BANDS = (("delta", 1.0, 4.0), ("theta", 4.0, 8.0), ("alpha", 8.0, 13.0), ("beta", 13.0, 30.0), ("gamma", 30.0, 45.0))


def _integrate(values: np.ndarray, coordinates: np.ndarray, *, axis: int = -1) -> np.ndarray:
    """Bridge NumPy 1.26's `trapz` and NumPy 2.4's `trapezoid` APIs."""
    if hasattr(np, "trapezoid"):
        return np.trapezoid(values, coordinates, axis=axis)
    return np.trapz(values, coordinates, axis=axis)


def _band_power(frequencies: np.ndarray, density: np.ndarray, low: float, high: float) -> float:
    index = (frequencies >= low) & (frequencies < high)
    if int(index.sum()) < 2:
        return 0.0
    return float(_integrate(density[index], frequencies[index]))


def feature_names(channel_count: int = 4) -> list[str]:
    names: list[str] = []
    for channel in range(channel_count):
        prefix = f"ch{channel}"
        names.extend([f"{prefix}_variance", f"{prefix}_amplitude_range", f"{prefix}_mean_absolute_amplitude"])
        names.extend(f"{prefix}_{name}_relative_power" for name, _, _ in BANDS)
        names.append(f"{prefix}_spectral_entropy")
    names.extend(f"correlation_{left}_{right}" for left in range(channel_count) for right in range(left + 1, channel_count))
    names.extend(["line_noise_to_broadband_power", *QUALITY_NAMES])
    names.extend(f"channel_{channel}_fully_observed" for channel in range(channel_count))
    return names


def extract_features(windows: np.ndarray, quality: np.ndarray, missing_channel_masks: np.ndarray) -> np.ndarray:
    """Compute stable M0 features from canonical normalized windows.

    `quality` and `missing_channel_masks` are inputs rather than implicit
    side-effects, so a signal-quality shortcut remains visible in the model.
    """
    if windows.ndim != 3 or windows.shape[1] != 4:
        raise ValueError("expected windows shaped [n, 4, samples]")
    if quality.shape[0] != windows.shape[0] or missing_channel_masks.shape != (windows.shape[0], 4):
        raise ValueError("quality and missing masks must align with windows")
    rows: list[np.ndarray] = []
    for window, quality_row, mask in zip(windows, quality, missing_channel_masks, strict=True):
        freqs, psd = signal.welch(window, fs=TARGET_SAMPLE_RATE_HZ, axis=-1, nperseg=min(256, window.shape[-1]))
        row: list[float] = []
        broadband = _integrate(psd[:, (freqs >= 1.0) & (freqs < 45.0)], freqs[(freqs >= 1.0) & (freqs < 45.0)], axis=-1)
        for channel in range(window.shape[0]):
            values = window[channel]
            row.extend(
                [
                    float(np.var(values)),
                    float(np.ptp(values)),
                    float(np.mean(np.abs(values))),
                ]
            )
            powers = np.asarray([_band_power(freqs, psd[channel], low, high) for _, low, high in BANDS])
            total = max(float(broadband[channel]), 1e-12)
            row.extend((powers / total).tolist())
            normalized = powers / max(float(powers.sum()), 1e-12)
            row.append(float(-np.sum(normalized * np.log(normalized + 1e-12)) / np.log(len(BANDS))))
        correlation = np.corrcoef(window)
        row.extend(float(np.nan_to_num(correlation[left, right])) for left in range(4) for right in range(left + 1, 4))
        line_band = (freqs >= 58.0) & (freqs <= 62.0)
        line = float(_integrate(psd[:, line_band], freqs[line_band], axis=-1).mean()) if int(line_band.sum()) >= 2 else 0.0
        row.append(line / max(float(np.mean(broadband)), 1e-12))
        row.extend(float(value) for value in quality_row)
        row.extend(float(value) for value in mask)
        rows.append(np.asarray(row, dtype=np.float32))
    matrix = np.vstack(rows) if rows else np.empty((0, len(feature_names())), dtype=np.float32)
    if matrix.shape[1] != len(feature_names()):
        raise RuntimeError("feature-name contract diverged from feature extraction")
    return matrix
