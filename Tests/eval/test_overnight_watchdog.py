"""Tests for the overnight zero-throughput watchdog (overnight-telemetry.py).

Covers the pure stall-decision predicate (`evaluate_capture_health`) across the
failure modes that mattered on night-2026-07-18 — never-started, stalled
mid-stream, a stale eeg_session symlink reading as a large-but-constant sample
count, plus the healthy and warm-up-grace cases — and the `abort_capture`
action: write CAPTURE_FAILED.json and terminate caffeinate so the Mac can sleep.

pytest-style + __main__ runner (pytest is not installed in the calibration venv).
"""
import importlib.util
import json
import subprocess
import sys
import tempfile
import time
from pathlib import Path


def _load(name):
    """Import a hyphenated Scripts/*.py as a module."""
    path = Path(__file__).resolve().parent.parent.parent / "Scripts" / f"{name}.py"
    spec = importlib.util.spec_from_file_location(name.replace("-", "_"), path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


tel = _load("overnight-telemetry")


def _run_ticks(sample_series, *, interval_min=1.0, warmup_min=2.0, stall_ticks=3):
    """Drive the sample series through the predicate exactly as the main loop does.

    Returns (fail_index, reason) — the tick index where it aborted, or (None, None).
    """
    prev, flat, ever = None, 0, False
    for i, s in enumerate(sample_series):
        elapsed = i * interval_min
        flat, ever, failed, reason = tel.evaluate_capture_health(
            prev, s, elapsed, ever, flat, warmup_min=warmup_min, stall_ticks=stall_ticks)
        prev = s
        if failed:
            return i, reason
    return None, None


def test_never_started_aborts_after_warmup():
    # 0 samples forever — but only counts against us once past warm-up.
    idx, reason = _run_ticks([0] * 20, warmup_min=2.0, stall_ticks=3)
    assert reason == "never_started", reason
    # first flat tick at elapsed>=2 (i=2), abort on the 3rd → i=4
    assert idx == 4, idx


def test_stale_symlink_constant_count_aborts():
    # The exact night-2026-07-18 shape: eeg_session points at a finished session,
    # so the count reads a large but CONSTANT number that never advances.
    idx, reason = _run_ticks([1_250_000] * 20, warmup_min=2.0, stall_ticks=3)
    assert reason == "never_started", reason
    assert idx == 4, idx


def test_stalled_mid_stream_aborts():
    # Grows, then the stream dies and the count flatlines.
    idx, reason = _run_ticks([100, 200, 300, 300, 300, 300, 300], warmup_min=2.0, stall_ticks=3)
    assert reason == "stalled_mid_stream", reason
    assert idx == 5, idx  # advanced through i=2, flat at i=3,4,5


def test_healthy_growth_never_aborts():
    idx, reason = _run_ticks([i * 100 for i in range(20)], warmup_min=2.0, stall_ticks=3)
    assert idx is None and reason is None, (idx, reason)


def test_warmup_grace_tolerates_zero_before_deadline():
    # Within warm-up, an all-zero start must NOT trip (app + symlink not up yet).
    idx, reason = _run_ticks([0, 0], warmup_min=10.0, stall_ticks=3)
    assert idx is None, (idx, reason)


def test_brief_gap_then_recovery_does_not_abort():
    # A single flat tick mid-stream must reset, not accumulate toward abort.
    idx, reason = _run_ticks([100, 200, 200, 300, 400, 500], warmup_min=2.0, stall_ticks=3)
    assert idx is None, (idx, reason)


def test_abort_capture_writes_marker_and_kills_caffeinate():
    with tempfile.TemporaryDirectory() as tmp:
        night = Path(tmp)
        metrics = night / "metrics.jsonl"
        # Stand in for caffeinate with a real, killable child process.
        proc = subprocess.Popen(["sleep", "30"])
        (night / ".caffeinate.pid").write_text(str(proc.pid))
        try:
            tel.abort_capture(night, "never_started", {"elapsed_min": 12.0}, 3, 60, metrics)

            marker = night / "CAPTURE_FAILED.json"
            assert marker.exists(), "CAPTURE_FAILED.json must be written"
            payload = json.loads(marker.read_text())
            assert payload["reason"] == "never_started"
            assert payload["flat_ticks"] == 3
            assert "detail" in payload and payload["detail"]

            # caffeinate stand-in should have received SIGTERM.
            for _ in range(60):
                if proc.poll() is not None:
                    break
                time.sleep(0.05)
            assert proc.poll() is not None, "caffeinate pid should have been terminated"
        finally:
            if proc.poll() is None:
                proc.kill()
            proc.wait(timeout=2)


def test_abort_capture_survives_missing_pid_file():
    # No .caffeinate.pid present — must still write the marker, not raise.
    with tempfile.TemporaryDirectory() as tmp:
        night = Path(tmp)
        tel.abort_capture(night, "stalled_mid_stream", {"elapsed_min": 90.0}, 3, 60,
                          night / "metrics.jsonl")
        assert (night / "CAPTURE_FAILED.json").exists()


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
