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
    to a target AC RMS value in uV (or callable(n) -> array) used to fill that column."""
    t = np.arange(n_samples, dtype=np.float64) / FS
    data = {}
    for ch in CHANNELS:
        amp = amplitudes.get(ch, 50.0)
        if callable(amp):
            data[ch] = amp(n_samples)
        else:
            # 10 Hz sine wave with exact AC RMS `amp` over integer half-cycles.
            data[ch] = float(amp) * np.sqrt(2.0) * np.sin(2.0 * np.pi * 10.0 * t)
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

    # Neither AF7 nor AF8 should be substituted; replacing saturated data
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


def test_classify_window_quality_non_finite():
    assert classify_window_quality(float("nan"), 100) == "saturated"
    assert classify_window_quality(float("inf"), 100) == "saturated"
    assert classify_window_quality(float("-inf"), 100) == "saturated"


def test_demean_option_handles_muse_dc_baseline():
    n = int(4 * FS)
    t = np.arange(n) / FS
    dc = 820.0
    healthy_ac = 25.0 * np.sqrt(2.0) * np.sin(2.0 * np.pi * 10.0 * t)
    saturated_ac = 450.0 * np.sqrt(2.0) * np.sin(2.0 * np.pi * 10.0 * t)
    df = pd.DataFrame({
        "TP9": np.full(n, dc),           # flat 820 uV DC -> dead after demean
        "AF7": dc + saturated_ac,        # 820 uV DC + 450 uV RMS AC -> saturated
        "AF8": dc + healthy_ac,          # 820 uV DC + 25 uV RMS AC -> healthy
        "TP10": dc + healthy_ac,         # 820 uV DC + 25 uV RMS AC -> healthy
    })
    # Default demean=True handles raw ~820 uV DC baseline without caller override.
    out, events = substitute_bad_channels(df, CHANNELS, FS, window_s=2.0)
    by_ch = {e.channel: e.reason for e in events}
    assert by_ch.get("TP9") == "dead"
    assert by_ch.get("AF7") == "saturated"
    assert np.allclose(out["TP9"].to_numpy(), df["TP10"].to_numpy())
    assert np.allclose(out["AF7"].to_numpy(), df["AF8"].to_numpy())


def test_validate_muse_physiology_analyze_with_dc_baseline():
    import importlib.util

    script_path = Path(__file__).resolve().parent.parent.parent / "Scripts" / "validate-muse-physiology.py"
    spec = importlib.util.spec_from_file_location("validate_muse_physiology", script_path)
    assert spec and spec.loader
    vmp = importlib.util.module_from_spec(spec)
    sys.modules["validate_muse_physiology"] = vmp
    spec.loader.exec_module(vmp)

    fs = float(vmp.SAMPLE_RATE)
    n = int(4 * fs)
    t = np.arange(n) / fs
    dc = 815.0  # Real Muse DC offset in uV

    def _make_board_matrix(ac_signals: list[np.ndarray]) -> np.ndarray:
        mat = np.zeros((7, n), dtype=np.float64)
        mat[0, :] = np.arange(n)
        for idx, sig in enumerate(ac_signals):
            mat[idx + 1, :] = dc + sig
        mat[6, :] = t
        return mat

    # 1. Eyes open: 15 uV RMS at 6 Hz (low alpha)
    open_sig = 15.0 * np.sqrt(2.0) * np.sin(2.0 * np.pi * 6.0 * t)
    data_open = _make_board_matrix([open_sig] * 4)

    # 2. Eyes closed: strong 10 Hz alpha (35 uV RMS) + background
    closed_sig = open_sig + 35.0 * np.sqrt(2.0) * np.sin(2.0 * np.pi * 10.0 * t)
    data_closed = _make_board_matrix([closed_sig] * 4)

    # 3. Blink: 120 uV peak deflection on AF7/AF8
    blink_sig = open_sig.copy()
    blink_sig[100:150] += 120.0
    data_blink = _make_board_matrix([open_sig, blink_sig, blink_sig, open_sig])

    # 4. Jaw clench: strong 20 Hz beta + 50 Hz EMG burst
    clench_sig = (
        open_sig
        + 30.0 * np.sqrt(2.0) * np.sin(2.0 * np.pi * 20.0 * t)
        + 30.0 * np.sqrt(2.0) * np.sin(2.0 * np.pi * 50.0 * t)
    )
    data_clench = _make_board_matrix([clench_sig] * 4)

    # 5. Head turn: slow 0.4 Hz 60 uV swing
    turn_sig = open_sig + 60.0 * np.sin(2.0 * np.pi * 0.4 * t)
    data_turn = _make_board_matrix([turn_sig] * 4)

    results, rc = vmp.analyze(data_open, data_closed, data_blink, data_clench, data_turn)
    assert rc == 0
    assert results["n_pass"] == 5
    assert results["contact_pass"] is True
    assert results["contact_healthy"] == ["TP9", "AF7", "AF8", "TP10"]
    assert results["blink_pass"] is True
    assert 100.0 <= results["blink_max_af7"] <= 200.0

    # Verify a single NaN in TP9 (ch 1) or AF7 (ch 2) does not poison Python's max()
    # into NaN across checks 1-4 while Step 5 flags TP9 as contact_saturated.
    data_open_nan = data_open.copy()
    data_open_nan[1, 10] = float("nan")
    data_blink_nan = data_blink.copy()
    data_blink_nan[2, 10] = float("nan")
    data_clench_nan = data_clench.copy()
    data_clench_nan[1, 10] = float("nan")
    data_turn_nan = data_turn.copy()
    data_turn_nan[1, 10] = float("nan")

    res_nan, _ = vmp.analyze(data_open_nan, data_closed, data_blink_nan, data_clench_nan, data_turn_nan)
    assert res_nan["alpha_pass"] is True
    assert res_nan["blink_pass"] is True
    assert res_nan["clench_pass"] is True
    assert res_nan["turn_pass"] is True
    assert res_nan["contact_pass"] is False
    assert "TP9" in res_nan["contact_saturated"]


def test_nan_in_channel_window_triggers_substitution():
    n = int(4 * FS)
    t = np.arange(n) / FS
    healthy_ac = 820.0 + 25.0 * np.sqrt(2.0) * np.sin(2.0 * np.pi * 10.0 * t)
    df = pd.DataFrame({
        "TP9": healthy_ac.copy(),
        "AF7": healthy_ac.copy(),
        "AF8": healthy_ac.copy(),
        "TP10": healthy_ac.copy(),
    })
    df.loc[100, "AF7"] = float("nan")
    out, events = substitute_bad_channels(df, CHANNELS, FS, window_s=2.0, demean=True)
    assert any(e.channel == "AF7" and e.reason == "saturated" for e in events)
    assert np.all(np.isfinite(out["AF7"].to_numpy()))


