"""Tests for Scripts/benchmark_muse_laya_health_gate.py (Muse S saturated AF7
Laya + channel-health gate benchmark, contralateral substitution OFF vs ON)."""
from __future__ import annotations

import json
from pathlib import Path
import sys

import numpy as np

REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPTS_DIR = REPO_ROOT / "Scripts"
if str(SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPTS_DIR))

from benchmark_muse_laya_health_gate import (
    evaluate_recording_off_vs_on,
    make_synthetic_saturated_af7_df,
    render_markdown_report,
    run_benchmark,
)


def test_synthetic_saturated_af7_off_vs_on():
    df = make_synthetic_saturated_af7_df(n_seconds=40, fs=256.0, seed=7)
    res = evaluate_recording_off_vs_on(df, "synthetic_af7_890uV", fs=256.0)

    off = res["substitution_off"]
    on = res["substitution_on"]

    assert off["channel_status"]["AF7"] == "saturated"
    assert off["channel_rms_uv"]["AF7"] > 800.0
    assert off["clean_window_rate"] == 0.0

    assert on["channel_status"]["AF7"] == "healthy"
    assert on["channel_rms_uv"]["AF7"] < 30.0
    assert on["clean_window_rate"] >= 0.90
    assert on["total_substituted_windows"] == 20
    assert on["substitutions_by_channel"]["AF7"]["substituted_from"] == "AF8"
    assert np.isclose(on["laya_kappa_whitened"], 1.0, atol=1e-6)
    assert res["deltas_on_minus_off"]["beta_power_reduction_ratio"] > 50.0


def test_healthy_recording_is_noop():
    df = make_synthetic_saturated_af7_df(n_seconds=20, fs=256.0, seed=11)
    # Replace AF7 with healthy AF8-like signal before evaluation
    df["AF7"] = df["AF8"] * 1.05 + 10.0
    res = evaluate_recording_off_vs_on(df, "synthetic_all_healthy", fs=256.0)

    assert res["substitution_off"]["channel_status"]["AF7"] == "healthy"
    assert res["substitution_on"]["total_substituted_windows"] == 0
    assert np.isclose(
        res["substitution_off"]["channel_rms_uv"]["AF7"],
        res["substitution_on"]["channel_rms_uv"]["AF7"],
    )


def test_bilateral_simultaneous_saturation_fails_closed():
    df = make_synthetic_saturated_af7_df(n_seconds=20, fs=256.0, seed=19)
    # Saturate both AF7 and AF8 simultaneously (> 200 uV RMS)
    df["AF8"] = -df["AF7"] * 0.96
    res = evaluate_recording_off_vs_on(df, "synthetic_bilateral_af7_af8_saturated", fs=256.0)

    off = res["substitution_off"]
    on = res["substitution_on"]
    assert off["channel_status"]["AF7"] == "saturated"
    assert off["channel_status"]["AF8"] == "saturated"
    assert on["total_substituted_windows"] == 0
    assert on["channel_status"]["AF7"] == "saturated"
    assert on["channel_status"]["AF8"] == "saturated"
    assert on["clean_window_rate"] == 0.0


def test_exported_benchmark_reports_exist_and_have_zero_dashes():
    json_path = REPO_ROOT / "Evaluation" / "reports" / "muse_s_af7_laya_health_gate_benchmark.json"
    md_path = REPO_ROOT / "Evaluation" / "reports" / "muse_s_af7_laya_health_gate_benchmark.md"
    assert json_path.exists()
    assert md_path.exists()

    json_txt = json_path.read_text()
    md_txt = md_path.read_text()
    assert "\u2014" not in json_txt and "\u2013" not in json_txt
    assert "\u2014" not in md_txt and "\u2013" not in md_txt

    payload = json.loads(json_txt)
    assert payload["schema_version"] == "muse-s-af7-laya-health-gate-benchmark-v1"
    assert payload["n_recordings"] >= 1
    agg = payload["aggregate_summary"]
    assert agg["mean_af7_rms_uv_off"] > agg["mean_af7_rms_uv_on"]
    assert agg["mean_clean_window_rate_on"] > agg["mean_clean_window_rate_off"]

    rendered = render_markdown_report(payload)
    assert "\u2014" not in rendered and "\u2013" not in rendered
