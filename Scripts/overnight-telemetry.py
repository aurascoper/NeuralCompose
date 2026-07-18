#!/usr/bin/env python3
"""
overnight-telemetry.py — engineering telemetry logger for overnight runs.

Records system and application metrics once per minute to a JSON-lines file
in the night directory. Designed to run alongside NeuralCompose, not inside it.

Usage:
    python3 Scripts/overnight-telemetry.py [--night-dir <dir>] [--interval 60]

Output: Recordings/night-YYYY-MM-DD/metrics.jsonl

Each line is a JSON object:
    {"timestamp": "...", "rss_mb": 123.4, "cpu_pct": 2.1, "free_disk_gb": 27.0,
     "ble_connected": true, "samples_received": 123456, "packet_loss": 0.001,
     "fsm_state": "Monitoring", "recording_size_mb": 15.2, "note": ""}
"""
import argparse
import json
import os
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
RECORDINGS_BASE = Path.home() / "Documents" / "NeuralCompose" / "Recordings"


def get_rss_mb(process_name="NeuralCompose"):
    """Get RSS in MB for a process by name."""
    try:
        result = subprocess.run(
            ["ps", "-A", "-o", "rss,comm"],
            capture_output=True, text=True, timeout=5
        )
        for line in result.stdout.strip().split("\n")[1:]:
            parts = line.strip().split(None, 1)
            if len(parts) == 2 and process_name.lower() in parts[1].lower():
                return float(parts[0]) / 1024.0
    except Exception:
        pass
    return None


def get_cpu_pct(process_name="NeuralCompose"):
    """Get CPU % for a process by name."""
    try:
        result = subprocess.run(
            ["ps", "-A", "-o", "%cpu,comm"],
            capture_output=True, text=True, timeout=5
        )
        for line in result.stdout.strip().split("\n")[1:]:
            parts = line.strip().split(None, 1)
            if len(parts) == 2 and process_name.lower() in parts[1].lower():
                return float(parts[0])
    except Exception:
        pass
    return None


def get_free_disk_gb(path="/"):
    """Get free disk space in GB."""
    try:
        st = os.statvfs(path)
        return st.f_bavail * st.f_frsize / (1024 ** 3)
    except Exception:
        return None


def resolve_recording_dir(night_dir):
    """Follow the `eeg_session` symlink to the real EEG sink.

    The app writes EEG into a separate `calibration_<ts>_muses/` dir, which
    dream-session.sh links as `night_dir/eeg_session` — created shortly AFTER
    telemetry starts, so this must be resolved per tick, not once. pathlib's
    glob/rglob do NOT descend a symlinked directory, so without following the
    link both the size and sample counts below stay pinned near zero even though
    an 80 MB eeg.csv exists one hop away. Mirrors
    overnight-review.py::find_eeg_session_dir.
    """
    if not night_dir:
        return night_dir
    link = night_dir / "eeg_session"
    if link.exists():
        try:
            return link.resolve()
        except OSError:
            return night_dir
    return night_dir


def get_recording_size_mb(night_dir):
    """Get total size of the actual EEG recording (via the eeg_session sink) in MB."""
    rec_dir = resolve_recording_dir(night_dir)
    if not rec_dir or not rec_dir.exists():
        return 0.0
    total = 0
    for f in rec_dir.rglob("*"):
        if f.is_file():
            try:
                total += f.stat().st_size
            except OSError:
                pass
    return total / (1024 ** 2)


def count_samples_csv(night_dir):
    """Estimate samples received from the largest CSV in the recording sink."""
    rec_dir = resolve_recording_dir(night_dir)
    if not rec_dir or not rec_dir.exists():
        return 0
    csvs = sorted(rec_dir.rglob("*.csv"), key=lambda f: f.stat().st_size if f.exists() else 0, reverse=True)
    if not csvs:
        return 0
    try:
        # Count lines minus header
        result = subprocess.run(["wc", "-l", str(csvs[0])], capture_output=True, text=True, timeout=5)
        lines = int(result.stdout.strip().split()[0])
        return max(0, lines - 1)
    except Exception:
        return 0


def get_app_state(night_dir):
    """Try to read FSM state from app's session log if it exists."""
    session_log = night_dir / "session.json" if night_dir else None
    if session_log and session_log.exists():
        try:
            with open(session_log) as f:
                data = json.load(f)
            return data.get("fsm_state", "Unknown")
        except Exception:
            pass
    return "Unknown"


def _fmt(value, width, prec):
    """Right-justified fixed-point string, or a right-justified '?' when value is None.

    Plain f-string interpolation like ``f"{x or '?':>7.1f}"`` still applies the
    float format spec to the '?' fallback and raises ValueError — the spec binds
    to the whole `x or default` expression, not conditionally on which branch fired.
    """
    if value is None:
        return f"{'?':>{width}}"
    return f"{value:>{width}.{prec}f}"


def check_ble_connected():
    """Check if a BrainFlow/Muse process is running (proxy for BLE)."""
    try:
        result = subprocess.run(
            ["pgrep", "-f", "NeuralCompose|brainflow|musel"],
            capture_output=True, text=True, timeout=5
        )
        return len(result.stdout.strip()) > 0
    except Exception:
        return False


def main():
    parser = argparse.ArgumentParser(description="Overnight engineering telemetry logger")
    parser.add_argument("--night-dir", type=str, default=None,
                        help="Path to the night recording directory")
    parser.add_argument("--interval", type=int, default=60,
                        help="Logging interval in seconds (default: 60)")
    parser.add_argument("--process-name", type=str, default="NeuralCompose",
                        help="Process name to track (default: NeuralCompose)")
    parser.add_argument("--stall-ticks", type=int, default=3,
                        help="flag a recording stall after this many ticks with no new samples while BLE is up")
    args = parser.parse_args()

    # Determine night directory
    today = datetime.now().strftime("%Y-%m-%d")
    if args.night_dir:
        night_dir = Path(args.night_dir)
    else:
        night_dir = RECORDINGS_BASE / f"night-{today}"
    night_dir.mkdir(parents=True, exist_ok=True)

    metrics_path = night_dir / "metrics.jsonl"
    start_time = datetime.now(timezone.utc)

    print(f"Overnight telemetry logger")
    print(f"  Night dir:    {night_dir}")
    print(f"  Metrics:      {metrics_path}")
    print(f"  Interval:     {args.interval}s")
    print(f"  Process:      {args.process_name}")
    print(f"  Started:      {start_time.isoformat()}")
    print(f"  Press Ctrl+C to stop.")
    print()

    prev_samples = None
    flat_ticks = 0
    try:
        while True:
            now = datetime.now(timezone.utc)
            entry = {
                "timestamp": now.isoformat(),
                "elapsed_min": round((now - start_time).total_seconds() / 60, 1),
                "rss_mb": get_rss_mb(args.process_name),
                "cpu_pct": get_cpu_pct(args.process_name),
                "free_disk_gb": get_free_disk_gb(),
                "ble_connected": check_ble_connected(),
                "samples_received": count_samples_csv(night_dir),
                "recording_size_mb": round(get_recording_size_mb(night_dir), 1),
                "fsm_state": get_app_state(night_dir),
                "packet_loss": None,  # populated if app writes it
                "osc_queue_depth": None,  # populated if app writes it
            }

            # Recording-stall detector: if the EEG CSV stops growing while the
            # app/BLE is still up, the headset has silently stalled — surface it
            # rather than logging a flat line for hours. Complements the in-app
            # stream-stall watchdog (AppViewModel.nextOrStall), which drives live
            # retry/fallback; this is the out-of-band observer that lands in
            # metrics.jsonl for overnight-review.
            # Only a recording that was flowing and then stopped counts as a
            # stall (samples > 0); "never started" is a different failure that
            # overnight-review already flags, and gating on it avoids a spurious
            # stall during the warm-up before the eeg_session symlink appears.
            samples = entry["samples_received"]
            if prev_samples is not None and samples <= prev_samples and samples > 0 and entry["ble_connected"]:
                flat_ticks += 1
            else:
                flat_ticks = 0
            prev_samples = samples
            entry["recording_stalled"] = flat_ticks >= args.stall_ticks

            with open(metrics_path, "a") as f:
                f.write(json.dumps(entry, default=str) + "\n")

            # Console summary
            print(f"  [{entry['elapsed_min']:6.1f}m] "
                  f"RSS={_fmt(entry['rss_mb'], 7, 1)}MB "
                  f"CPU={_fmt(entry['cpu_pct'], 5, 1)}% "
                  f"Disk={_fmt(entry['free_disk_gb'], 5, 1)}GB "
                  f"BLE={'Y' if entry['ble_connected'] else 'N'} "
                  f"Samples={entry['samples_received']:>8d} "
                  f"Rec={entry['recording_size_mb']:>7.1f}MB "
                  f"FSM={entry['fsm_state']}")
            if entry["recording_stalled"]:
                print(f"  ⚠ STALL: no new EEG samples for {flat_ticks} ticks "
                      f"(~{flat_ticks * args.interval}s) while BLE is up — recording may be dead.")

            time.sleep(args.interval)

    except KeyboardInterrupt:
        elapsed = (datetime.now(timezone.utc) - start_time).total_seconds() / 60
        print(f"\nStopped after {elapsed:.1f} minutes. Metrics in {metrics_path}")


if __name__ == "__main__":
    main()