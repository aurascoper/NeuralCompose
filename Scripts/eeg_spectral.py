#!/usr/bin/env python3
"""
eeg_spectral.py — shared spectral-feature + state-descriptor derivation for the
4-channel Muse S montage (TP9, AF7, AF8, TP10).

Phase 3.6 of NeuralCompose aligns a *continuous* EEG-window embedding with a
*text* embedding space. The text target for each rolling 2-second window is a
natural-language "spectral state descriptor" derived — self-supervised — from
that window's own Power Spectral Density: band powers → ratios → descriptor.
This module owns that derivation so the trainer (train_joint_embedding.py) and
any later analysis share one definition of "what state does this window look
like", exactly as eeg_channel_quality.py owns channel-health classification.

Honesty note (kept on the record): descriptors are *primarily spectral*
(e.g. "alpha-dominant"). The cognitive adjectives ("relaxed wakefulness",
"high cognitive load", "drowsy / fatigued") are a heuristic gloss so the
resulting BGE-small-en-v1.5 embeddings read naturally as Phase 4.0 prompt
prefixes — they are NOT a validated cognitive-state classifier. Band powers on
a 4-electrode montage are physically real; the state-word mapping is an
interpretive convenience. Band definitions mirror analyze-eeg-session.py::BANDS.
"""
from __future__ import annotations

import numpy as np
from scipy import signal

# Mirror analyze-eeg-session.py::BANDS — keep in sync if those change.
BANDS = {
    "delta": (0.5, 4.0),
    "theta": (4.0, 8.0),
    "alpha": (8.0, 13.0),
    "beta": (13.0, 30.0),
}

_EPS = 1e-8


def _resolve_trapezoid(namespace):
    """Pick the integrator NumPy actually exposes.

    `trapezoid` is the numpy>=2.0 name and `trapz` the numpy<2.0 one. Resolving
    it lazily is the whole point: the previous form was

        getattr(np, "trapezoid", getattr(np, "trapz"))

    and Python evaluates that default *before* the lookup it is a fallback for.
    On numpy 2.x, which removed `trapz` outright, it raised `AttributeError` at
    import — on precisely the version the fallback existed to support. Every
    `Tests/eval` module reaching this file failed collection, which is how it
    survived: nothing in CI imported it.
    """
    trapezoid = getattr(namespace, "trapezoid", None)
    if trapezoid is not None:
        return trapezoid
    return namespace.trapz


_trapz = _resolve_trapezoid(np)


def band_power(freqs: np.ndarray, psd: np.ndarray, band: tuple[float, float]) -> float:
    """Integrate a PSD over [lo, hi]. Mirrors analyze-eeg-session.py::band_power."""
    lo, hi = band
    mask = (freqs >= lo) & (freqs <= hi)
    if not np.any(mask):
        return 0.0
    return float(_trapz(psd[mask], freqs[mask]))


def welch_band_powers(window: np.ndarray, fs: float) -> dict[str, float]:
    """Mean band powers across channels for one window.

    `window` is [n_channels, n_samples] — the trainer's per-window layout.
    Returns {band_name: mean_power_across_channels} for the four BANDS.
    """
    window = np.asarray(window, dtype=np.float64)
    if window.ndim != 2:
        raise ValueError(f"window must be 2-D [channels, samples], got shape {window.shape}")
    n_channels, n_samples = window.shape
    nperseg = min(n_samples, max(int(fs * 4), 8))
    powers = {name: 0.0 for name in BANDS}
    for ch in range(n_channels):
        # Welch already tapers each segment with a Hann window (limits the
        # spectral leakage a finite epoch causes) and removes the segment mean
        # (detrend="constant" — kills DC/baseline drift). Both are scipy defaults;
        # stated explicitly so a future edit can't silently drop them.
        freqs, psd = signal.welch(window[ch], fs=fs, nperseg=nperseg,
                                  window="hann", detrend="constant")
        for name, band in BANDS.items():
            powers[name] += band_power(freqs, psd, band)
    return {name: p / max(n_channels, 1) for name, p in powers.items()}


def spectral_ratios(band_powers: dict[str, float]) -> dict[str, float]:
    """Derive interpretable, epsilon-guarded band ratios from mean band powers.

    These are *relative* measures (band/band, band/total): a broadband amplitude
    change — e.g. electrode-impedance drift multiplying every band by a common
    gain — cancels in the ratio. (This does NOT cancel band-*specific* artifacts
    like a blink dumping energy into delta; reject those with window_is_clean.)
    """
    delta = band_powers.get("delta", 0.0)
    theta = band_powers.get("theta", 0.0)
    alpha = band_powers.get("alpha", 0.0)
    beta = band_powers.get("beta", 0.0)
    total = delta + theta + alpha + beta + _EPS
    return {
        "theta_alpha": theta / (alpha + _EPS),
        "alpha_beta": alpha / (beta + _EPS),
        "beta_alpha": beta / (alpha + _EPS),
        # Pope et al. engagement index: beta / (alpha + theta).
        "engagement": beta / (alpha + theta + _EPS),
        # Fraction of low-frequency (delta + theta) power — a drowsiness proxy.
        "slow_fraction": (delta + theta) / total,
    }


# Frontal blinks/EOG saccades and movement/EMG twitches produce voltage swings
# far larger than cortical rhythms. A blink is band-SPECIFIC (a huge slow delta
# transient), so it survives ratio normalization and would masquerade as
# slow-wave/deep activity. Reject such windows on raw amplitude BEFORE any
# spectral projection. ~150 uV cleanly separates real EEG (tens of uV) from
# blink/movement artifacts (hundreds of uV), well under Muse ADC saturation.
ARTIFACT_PEAK_UV = 150.0


def window_is_clean(window: np.ndarray, threshold_uv: float = ARTIFACT_PEAK_UV) -> bool:
    """True if no channel in the window swings beyond +/-threshold_uv.

    `window` is [channels, samples]. Use to drop blink/EOG/movement artifacts
    before computing spectral features — band ratios cancel a broadband gain
    change (impedance drift) but NOT a band-specific spike like a blink.
    """
    w = np.asarray(window, dtype=np.float64)
    if w.size == 0:
        return False
    return bool(np.max(np.abs(w)) <= threshold_uv)


# The closed target vocabulary. Order is stable so it can be written to metadata
# and used as the fixed retrieval@1 candidate set. Each phrase leads with the
# spectral fact and follows with the heuristic cognitive gloss.
STATE_DESCRIPTORS = [
    "drowsy and fatigued, theta-dominant low-frequency brain activity",
    "relaxed wakefulness, alpha-dominant brain activity",
    "engaged and focused, beta-dominant brain activity",
    "high cognitive load, elevated beta over alpha brain activity",
    "neutral baseline brain activity with no dominant rhythm",
]


def descriptor_for_ratios(ratios: dict[str, float]) -> str:
    """Map spectral ratios to one natural-language state descriptor.

    ── DOMAIN-JUDGMENT CORE (Phase 3.6) ─────────────────────────────────────
    This heuristic decides which spectral signature reads as which cognitive
    gloss — and therefore *what text each EEG window is aligned to*. The
    thresholds below are deliberate, tunable defaults: the single place where
    the montage owner's judgment most changes behaviour. Adjust the cut points
    (or swap in per-subject calibration) as real recordings inform them; the
    only invariant is that every branch returns a member of STATE_DESCRIPTORS.
    ─────────────────────────────────────────────────────────────────────────
    """
    slow = ratios.get("slow_fraction", 0.0)
    theta_alpha = ratios.get("theta_alpha", 0.0)
    beta_alpha = ratios.get("beta_alpha", 0.0)
    engagement = ratios.get("engagement", 0.0)

    if slow > 0.6 and theta_alpha > 1.2:
        return STATE_DESCRIPTORS[0]   # drowsy / fatigued (theta-dominant, slow)
    if beta_alpha > 1.5 or engagement > 1.0:
        return STATE_DESCRIPTORS[3]   # high cognitive load (beta >> alpha)
    if beta_alpha > 0.9:
        return STATE_DESCRIPTORS[2]   # engaged / focused (beta-dominant)
    if theta_alpha < 0.8 and beta_alpha < 0.9:
        return STATE_DESCRIPTORS[1]   # relaxed wakefulness (alpha-dominant)
    return STATE_DESCRIPTORS[4]       # neutral baseline (no dominant rhythm)
