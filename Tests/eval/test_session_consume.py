"""Tests for the session capture/consumption tooling (consume-session.py,
run-session-protocol.py).

Covers marker clustering, segmentation, the focus/drowsy threshold sweep, the
heuristic sleep-stage labeller, an end-to-end review through the real blink
detector, and the cue-helper dry run. pytest-style + __main__ runner (pytest is
not installed in the calibration venv).
"""
import importlib.util
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent.parent / "Scripts"))

import numpy as np
import pandas as pd

FS = 256.0
CHANNELS = ["TP9", "AF7", "AF8", "TP10"]


def _load(name):
    """Import a hyphenated Scripts/*.py as a module."""
    path = Path(__file__).resolve().parent.parent.parent / "Scripts" / f"{name}.py"
    spec = importlib.util.spec_from_file_location(name.replace("-", "_"), path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


csm = _load("consume-session")
proto = _load("run-session-protocol")


# ── synthetic signal builders ────────────────────────────────────────────

def _sine(freq, dur_s, amp):
    n = int(dur_s * FS)
    return amp * np.sin(2 * np.pi * freq * np.arange(n) / FS)


def _blink_burst(n_blinks=5, gap=0.6, amp=500.0):
    dur = n_blinks * gap + 0.5
    n = int(dur * FS)
    t = np.arange(n) / FS
    sig = np.zeros(n)
    for k in range(n_blinks):
        sig += amp * np.exp(-0.5 * ((t - (0.3 + k * gap)) / 0.05) ** 2)
    return sig, n


def _make_session():
    """Build a synthetic session: blink-tag → focus(beta) → tag → drowsy(theta)
    → tag → sleep(delta). Frontal channels carry the blink bursts."""
    blocks = []  # each: dict(frontal=array, band=array, n)

    def add_tag():
        b, n = _blink_burst()
        blocks.append({"frontal": b, "band": np.zeros(n), "n": n})

    def add_band(freq, dur, amp):
        n = int(dur * FS)
        blocks.append({"frontal": _sine(freq, dur, amp), "band": _sine(freq, dur, amp), "n": n})

    add_tag()
    add_band(20.0, 12.0, 35.0)   # focus: beta-dominant
    add_tag()
    add_band(6.0, 12.0, 40.0)    # drowsy: theta-dominant
    add_tag()
    add_band(2.0, 70.0, 40.0)    # sleep: delta-dominant

    rng = np.random.default_rng(0)
    total = sum(b["n"] for b in blocks)
    data = {ch: np.zeros(total) for ch in CHANNELS}
    pos = 0
    for b in blocks:
        n = b["n"]
        for ch in CHANNELS:
            base = b["frontal"] if ch in ("AF7", "AF8") else b["band"]
            data[ch][pos:pos + n] = base + rng.normal(0, 2.0, n)
        pos += n
    df = pd.DataFrame(data)
    df.insert(0, "t_seconds", 1.783e9 + np.arange(total) / FS)
    return df, CHANNELS, FS


# ── unit tests ────────────────────────────────────────────────────────────

def test_cluster_blink_bursts():
    events = [{"start_s": t, "end_s": t + 0.1} for t in (0.0, 0.6, 1.2, 1.8, 2.4)]
    events += [{"start_s": t, "end_s": t + 0.1} for t in (10.0, 10.6, 11.2, 11.8, 12.4)]
    events += [{"start_s": 20.0, "end_s": 20.1}]  # lone blink — not a marker
    markers = csm.cluster_blink_bursts(events)
    assert len(markers) == 2, f"expected 2 bursts, got {len(markers)}"
    assert all(m["n_blinks"] == 5 for m in markers)
    assert markers[0]["center_s"] < markers[1]["center_s"]


def test_segment_from_markers():
    markers = [{"start_s": 0, "end_s": 4, "center_s": 2},
               {"start_s": 20, "end_s": 24, "center_s": 22},
               {"start_s": 40, "end_s": 44, "center_s": 42}]
    segs = csm.segment_from_markers(markers, ["focus", "drowsy", "sleep"], total_s=100.0)
    assert [s["label"] for s in segs] == ["focus", "drowsy", "sleep"]
    assert segs[0]["start_s"] == 4 and segs[0]["end_s"] == 20      # marker0.end → marker1.start
    assert segs[2]["end_s"] == 100.0                                # last runs to end


def test_sweep_threshold_separates():
    rng = np.random.default_rng(1)
    focus_vals = list(rng.normal(2.0, 0.2, 40))   # high beta/alpha
    drowsy_vals = list(rng.normal(0.4, 0.1, 40))  # low beta/alpha
    values = focus_vals + drowsy_vals
    labels = ["focus"] * 40 + ["drowsy"] * 40
    tau, acc = csm.sweep_threshold(values, labels, "focus", "drowsy")
    assert acc > 0.9, f"sweep should separate cleanly, got balanced_acc={acc}"
    assert 0.4 < tau < 2.0, f"threshold should sit between the groups, got {tau}"


def test_epoch_stage_deep_and_rem():
    ana = csm._load_analyzer()
    n = int(30 * FS)
    # deep: strong delta on all channels
    deep = np.stack([_sine(2.0, 30.0, 60.0) for _ in CHANNELS])
    assert csm.epoch_stage(deep, FS, CHANNELS, ["AF7", "AF8"], ana) == "deep"
    # rem: low-amplitude broadband noise + frontal EOG spikes
    rng = np.random.default_rng(2)
    rem = rng.normal(0, 10.0, (len(CHANNELS), n))
    t = np.arange(n) / FS
    for k in range(8):
        bump = 300.0 * np.exp(-0.5 * ((t - (2 + k * 3.0)) / 0.05) ** 2)
        rem[CHANNELS.index("AF7")] += bump
        rem[CHANNELS.index("AF8")] += bump
    assert csm.epoch_stage(rem, FS, CHANNELS, ["AF7", "AF8"], ana) == "rem"


def test_end_to_end_review():
    df, channels, fs = _make_session()
    review = csm.review_session(df, channels, fs, labels=["focus", "drowsy", "sleep"],
                                do_active=True, do_sleep=True, model_dir=None)
    assert len(review["markers"]) == 3, f"expected 3 tag markers, got {len(review['markers'])}"
    assert [s["label"] for s in review["segments"]] == ["focus", "drowsy", "sleep"]
    assert "threshold_suggestions" in review["active_split"], review["active_split"]
    ba = review["active_split"]["threshold_suggestions"]["beta_alpha_cut"]["balanced_acc"]
    assert ba > 0.8, f"focus/drowsy should separate on beta/alpha, got {ba}"
    assert review["sleep_timeline"]["n_epochs"] >= 1


def test_protocol_dry_run_writes_log():
    with tempfile.TemporaryDirectory() as tmp:
        out = proto.run_protocol([("focus", 600), ("drowsy", 600), ("sleep", 0)],
                                 tag_blinks=5, tag_window=8.0, out_dir=Path(tmp), dry_run=True)
        log = out["log"]
        assert [s["label"] for s in log["segments"]] == ["focus", "drowsy", "sleep"]
        assert all("cue_unix" in s and "start_unix" in s for s in log["segments"])
        assert Path(out["path"]).exists()


if __name__ == "__main__":
    tests = [v for k, v in sorted(globals().items()) if k.startswith("test_") and callable(v)]
    failed = 0
    for t in tests:
        try:
            t()
            print(f"PASS {t.__name__}")
        except Exception as exc:  # noqa: BLE001
            failed += 1
            import traceback
            traceback.print_exc()
            print(f"FAIL {t.__name__}: {exc}")
    print(f"\n{len(tests) - failed}/{len(tests)} passed")
    sys.exit(1 if failed else 0)
