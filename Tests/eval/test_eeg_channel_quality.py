"""Tests for the shared EEG channel-quality classification/substitution module."""
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent / "Scripts"))

import numpy as np
import pandas as pd
from eeg_channel_quality import (
    classify_window_quality,
    substitute_bad_channels,
    summarize_substitutions,
    DEAD_RMS_UV,
    SATURATED_RMS_UV,
    MIN_SAMPLES,
)

FS = 256.0
CHANNELS = ["TP9", "AF7", "AF8", "TP10"]


def _make_df(n_samples: int, amplitudes: dict) -> pd.DataFrame:
    """Build a synthetic 4-channel DataFrame. `amplitudes` maps channel name
    to a constant value (or callable(n) -> array) used to fill that column."""
    rng = np.random.default_rng(0)
    data = {}
    for ch in CHANNELS:
        amp = amplitudes.get(ch, 50.0)
        if callable(amp):
            data[ch] = amp(n_samples)
        else:
            # Small deterministic noise around the target amplitude so RMS
            # is well-defined and not a degenerate all-equal column.
            data[ch] = amp + rng.normal(0, amp * 0.01 + 1e-6, n_samples)
    return pd.DataFrame(data)


def test_classify_window_quality_boundaries():
    assert classify_window_quality(1.0, 100) == "dead"
    assert classify_window_quality(50.0, 100) == "healthy"
    assert classify_window_quality(SATURATED_RMS_UV + 1, 100) == "saturated"
    assert classify_window_quality(50.0, MIN_SAMPLES - 1) == "unknown"
    assert classify_window_quality(DEAD_RMS_UV + 1, MIN_SAMPLES) == "healthy"


def test_healthy_channels_never_substituted():
    n = int(4 * FS)  # 4 windows at window_s=2.0
    df = _make_df(n, {"TP9": 50.0, "AF7": 60.0, "AF8": 55.0, "TP10": 45.0})
    out, events = substitute_bad_channels(df, CHANNELS, FS)
    assert events == []
    for ch in CHANNELS:
        assert np.allclose(out[ch].to_numpy(), df[ch].to_numpy())


def test_saturated_channel_substituted_from_pair():
    n = int(4 * FS)
    df = _make_df(n, {"TP9": 50.0, "AF7": 900.0, "AF8": 50.0, "TP10": 45.0})
    out, events = substitute_bad_channels(df, CHANNELS, FS)

    assert len(events) > 0
    assert all(e.channel == "AF7" for e in events)
    assert all(e.paired_from == "AF8" for e in events)
    assert all(e.reason == "saturated" for e in events)
    # AF7's substituted values should now match AF8's original data exactly
    # over every window that was substituted.
    assert np.allclose(out["AF7"].to_numpy(), df["AF8"].to_numpy())
    # Untouched channels stay untouched.
    assert np.allclose(out["TP9"].to_numpy(), df["TP9"].to_numpy())
    assert np.allclose(out["TP10"].to_numpy(), df["TP10"].to_numpy())


def test_dead_channel_substituted_from_pair():
    n = int(4 * FS)
    df = _make_df(n, {"TP9": 0.1, "AF7": 60.0, "AF8": 55.0, "TP10": 45.0})
    out, events = substitute_bad_channels(df, CHANNELS, FS)

    assert len(events) > 0
    assert all(e.channel == "TP9" for e in events)
    assert all(e.paired_from == "TP10" for e in events)
    assert all(e.reason == "dead" for e in events)
    assert np.allclose(out["TP9"].to_numpy(), df["TP10"].to_numpy())


def test_both_paired_channels_bad_no_substitution():
    n = int(4 * FS)
    df = _make_df(n, {"TP9": 50.0, "AF7": 900.0, "AF8": 900.0, "TP10": 45.0})
    out, events = substitute_bad_channels(df, CHANNELS, FS)

    # Neither AF7 nor AF8 should be substituted — replacing saturated data
    # with equally-saturated data from the pair is never a real fix.
    assert events == []
    assert np.allclose(out["AF7"].to_numpy(), df["AF7"].to_numpy())
    assert np.allclose(out["AF8"].to_numpy(), df["AF8"].to_numpy())


def test_summarize_substitutions_reports_window_count_and_duration():
    n = int(4 * FS)
    df = _make_df(n, {"TP9": 50.0, "AF7": 900.0, "AF8": 50.0, "TP10": 45.0})
    _, events = substitute_bad_channels(df, CHANNELS, FS, window_s=2.0)
    summary = summarize_substitutions(events)

    assert "AF7" in summary
    assert summary["AF7"]["substituted_from"] == "AF8"
    assert summary["AF7"]["window_count"] == len(events)
    assert summary["AF7"]["total_seconds"] > 0.0
