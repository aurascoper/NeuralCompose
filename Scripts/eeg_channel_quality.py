#!/usr/bin/env python3
"""
eeg_channel_quality.py — shared per-channel quality classification and
bad-channel substitution for the 4-channel Muse S montage
(TP9, AF7, AF8, TP10).

Mirrors Sources/BCICore/Preprocessing/ChannelHealthThresholds.swift's
thresholds so the offline Python pipeline (analyze-eeg-session.py,
train-intent-classifier.py) and the live Swift app classify channel
health the same way. If those Swift thresholds change, update the
constants below to match.

Substitution is a consumption-time concern only — it never touches raw
recordings on disk (CalibrationRecorder.swift's CSV writer is untouched)
and it must never replace the raw-data-based per-channel diagnostics
computed elsewhere (e.g. analyze-eeg-session.py's assess_channel_quality),
since those are what let a future session show whether a channel has
actually recovered. Substitution only improves downstream *feature
computation* (band power, PSD, training tensors, etc.).
"""
from __future__ import annotations

from dataclasses import dataclass

import numpy as np
import pandas as pd

# Mirrors ChannelHealthThresholds.swift's `.default`
# (Sources/BCICore/Preprocessing/ChannelHealthThresholds.swift) — keep in
# sync if those values change.
DEAD_RMS_UV = 2.0
SATURATED_RMS_UV = 200.0
MIN_SAMPLES = 32

# Only sensible pairing for a 4-electrode Muse montage: the
# anterior-frontal pair and the temporoparietal pair. Full
# spherical-spline / multi-neighbor interpolation needs more electrodes
# than this montage has.
CHANNEL_PAIRS = {
    "AF7": "AF8",
    "AF8": "AF7",
    "TP9": "TP10",
    "TP10": "TP9",
}


def classify_window_quality(rms: float, n_samples: int) -> str:
    """Classify a single RMS measurement, mirroring
    ChannelHealthThresholds.status(forRMS:samples:). Returns one of
    "unknown" / "healthy" / "saturated" / "dead"."""
    if n_samples < MIN_SAMPLES:
        return "unknown"
    if rms > SATURATED_RMS_UV:
        return "saturated"
    if rms < DEAD_RMS_UV:
        return "dead"
    return "healthy"


@dataclass
class SubstitutionEvent:
    channel: str
    paired_from: str
    start_s: float
    end_s: float
    rms_uv: float
    reason: str  # "saturated" | "dead"


def substitute_bad_channels(
    df: pd.DataFrame,
    channels: list[str],
    fs: float,
    window_s: float = 2.0,
) -> tuple[pd.DataFrame, list[SubstitutionEvent]]:
    """Per-window, adaptive bad-channel substitution.

    For each channel and each non-overlapping `window_s` window, classify
    that window's RMS via `classify_window_quality`. If the window is
    "saturated" or "dead" and the channel's paired channel (per
    CHANNEL_PAIRS) is present and itself healthy for that same window,
    replace the bad channel's samples in that window with the paired
    channel's samples. A channel whose pair is also bad in that window is
    left untouched — never substitute garbage with equally-bad garbage.

    Returns a new DataFrame (the input is not mutated) and a log of every
    substitution made, so nothing here is silent.
    """
    out = df.copy()
    win = max(int(window_s * fs), MIN_SAMPLES)
    n = len(df)
    events: list[SubstitutionEvent] = []

    for ch in channels:
        pair = CHANNEL_PAIRS.get(ch)
        if pair is None or pair not in channels:
            continue
        col_idx = out.columns.get_loc(ch)
        x = df[ch].to_numpy()
        px = df[pair].to_numpy()
        for start in range(0, n, win):
            end = min(start + win, n)
            seg = x[start:end]
            if len(seg) == 0:
                continue
            rms = float(np.sqrt(np.mean(seg ** 2)))
            status = classify_window_quality(rms, len(seg))
            if status not in ("saturated", "dead"):
                continue
            pair_seg = px[start:end]
            pair_rms = float(np.sqrt(np.mean(pair_seg ** 2))) if len(pair_seg) else 0.0
            if classify_window_quality(pair_rms, len(pair_seg)) != "healthy":
                continue
            out.iloc[start:end, col_idx] = pair_seg
            events.append(SubstitutionEvent(
                channel=ch,
                paired_from=pair,
                start_s=start / fs,
                end_s=end / fs,
                rms_uv=rms,
                reason=status,
            ))

    return out, events


def summarize_substitutions(events: list[SubstitutionEvent]) -> dict:
    """Roll a substitution log into a compact per-channel summary
    suitable for embedding in a JSON report or printing to stdout."""
    by_channel: dict[str, dict] = {}
    for e in events:
        entry = by_channel.setdefault(e.channel, {
            "substituted_from": e.paired_from,
            "window_count": 0,
            "total_seconds": 0.0,
        })
        entry["window_count"] += 1
        entry["total_seconds"] += e.end_s - e.start_s
    return by_channel
