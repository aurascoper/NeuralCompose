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
import signal
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


def get_git_sha():
    """Short git SHA of the repo this script runs from, or None.

    Stamped into every metrics line so a morning review can tell whether a
    long-running overnight process was pinned to code that predates a later
    capture fix — the exact trap behind the night-2026-07-18 blind run, where
    the process launched ~3h before the symlink-follow fix was committed and
    never reloaded it.
    """
    try:
        result = subprocess.run(
            ["git", "-C", str(REPO_ROOT), "rev-parse", "--short", "HEAD"],
            capture_output=True, text=True, timeout=5
        )
        return result.stdout.strip() or None
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


def check_ble_connected(process_name="NeuralCompose"):
    """True if the app process is running — an app-liveness proxy for BLE.

    The prior version ran ``pgrep -f "NeuralCompose|brainflow|musel"``, which
    matched THIS logger's own command line (its ``--night-dir`` argument contains
    'NeuralCompose'), so it self-satisfied and reported connected even with the
    app dead — a monitor that can be true just by observing itself. Match the
    app binary's ``comm`` instead (no python/shell/caffeinate process shares that
    comm), and exclude our own PID/parent defensively. This is app-liveness, not
    a true BLE-link probe — only the app can see the actual link — but it is at
    least decoupled from the logger's own existence. Field name kept as
    ``ble_connected`` for metrics.jsonl / overnight-review back-compat.
    """
    try:
        result = subprocess.run(
            ["ps", "-A", "-o", "pid,comm"],
            capture_output=True, text=True, timeout=5
        )
        own = {os.getpid(), os.getppid()}
        for line in result.stdout.strip().split("\n")[1:]:
            parts = line.strip().split(None, 1)
            if len(parts) == 2 and parts[0].isdigit():
                pid, comm = int(parts[0]), parts[1]
                if pid not in own and process_name.lower() in comm.lower():
                    return True
        return False
    except Exception:
        return False


def evaluate_capture_health(prev_samples, samples, elapsed_min, ever_flowed,
                            flat_ticks, *, warmup_min, stall_ticks):
    """Decide whether the capture has failed. Pure function (no I/O) for testability.

    Returns ``(flat_ticks, ever_flowed, failed, reason)``.

    Two failure modes, both aborts under the chosen policy:
      - ``stalled_mid_stream``: samples grew, then stopped advancing for
        ``stall_ticks`` consecutive ticks — the stream silently died mid-record.
      - ``never_started``: no growth at all past ``warmup_min`` for ``stall_ticks``
        consecutive ticks — covers both a dead/idle app and an ``eeg_session``
        symlink pinned to a stale, already-complete session (samples read as a
        large but constant number, never advancing). This is exactly the
        night-2026-07-18 state.

    During warm-up with no data yet (app + eeg_session symlink may not be up),
    flat ticks do not accumulate, so the legitimate startup window can't trip it.
    """
    advanced = prev_samples is not None and samples > prev_samples
    if advanced:
        return 0, True, False, None
    # No new samples this tick.
    if ever_flowed or elapsed_min >= warmup_min:
        flat_ticks += 1
    failed = flat_ticks >= stall_ticks
    reason = ("stalled_mid_stream" if ever_flowed else "never_started") if failed else None
    return flat_ticks, ever_flowed, failed, reason


def abort_capture(night_dir, reason, last_entry, flat_ticks, interval, metrics_path):
    """Fail loud and release the machine (the 'abort + release + FAILED marker' policy).

    Writes CAPTURE_FAILED.json (so the morning review reads a loud failure instead
    of a false green), terminates caffeinate via its pid file so the Mac is free to
    sleep, and returns — the caller exits, stopping telemetry. Deliberately does NOT
    kill the app; an idle app holds no sleep assertion, caffeinate is what pins the
    machine awake.
    """
    now = datetime.now(timezone.utc)
    detail = {
        "never_started": ("No EEG samples were ever recorded past warm-up — the app either "
                          "wasn't recording or eeg_session points at a stale, non-growing session."),
        "stalled_mid_stream": ("EEG recording grew and then stopped for the stall window while the "
                               "app was still up — the stream silently died."),
    }.get(reason, reason)
    marker = night_dir / "CAPTURE_FAILED.json"
    payload = {
        "failed_at": now.isoformat(),
        "reason": reason,
        "detail": detail,
        "flat_ticks": flat_ticks,
        "stall_window_s": flat_ticks * interval,
        "elapsed_min": last_entry.get("elapsed_min"),
        "last_metrics": last_entry,
        "metrics_path": str(metrics_path),
        "policy": "abort+release: telemetry exits and caffeinate is terminated so the Mac may sleep.",
    }
    try:
        marker.write_text(json.dumps(payload, indent=2, default=str))
    except OSError as e:
        print(f"  ⚠ could not write {marker.name}: {e}")

    killed = []
    caff_pid_file = night_dir / ".caffeinate.pid"
    try:
        pid = int(caff_pid_file.read_text().strip())
        os.kill(pid, signal.SIGTERM)
        killed.append(pid)
    except (FileNotFoundError, ValueError, ProcessLookupError, PermissionError, OSError):
        pass

    print()
    print(f"  ✗ CAPTURE FAILED ({reason}) after {last_entry.get('elapsed_min', 0):.1f} min — {detail}")
    print(f"    Wrote {marker.name}; terminated caffeinate {killed or '(none found)'}; "
          f"telemetry exiting so the Mac can sleep.")


def main():
    parser = argparse.ArgumentParser(description="Overnight engineering telemetry logger")
    parser.add_argument("--night-dir", type=str, default=None,
                        help="Path to the night recording directory")
    parser.add_argument("--interval", type=int, default=60,
                        help="Logging interval in seconds (default: 60)")
    parser.add_argument("--process-name", type=str, default="NeuralCompose",
                        help="Process name to track (default: NeuralCompose)")
    parser.add_argument("--stall-ticks", type=int, default=3,
                        help="abort after this many consecutive ticks with no new EEG samples")
    parser.add_argument("--warmup-min", type=float, default=10.0,
                        help="grace period (min) before a never-started (0-sample) run counts as a "
                             "failure — covers app launch + eeg_session symlink appearing (default: 10)")
    parser.add_argument("--no-abort", action="store_true",
                        help="detect and log stalls but do NOT abort/kill caffeinate (legacy log-only behavior)")
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
    git_sha = get_git_sha()

    print(f"Overnight telemetry logger")
    print(f"  Night dir:    {night_dir}")
    print(f"  Metrics:      {metrics_path}")
    print(f"  Interval:     {args.interval}s")
    print(f"  Process:      {args.process_name}")
    print(f"  Code:         git {git_sha or '(unknown)'}")
    print(f"  Watchdog:     {'log-only (--no-abort)' if args.no_abort else 'abort+release'} "
          f"after {args.stall_ticks} flat ticks; warm-up {args.warmup_min:.0f}m")
    print(f"  Started:      {start_time.isoformat()}")
    print(f"  Press Ctrl+C to stop.")
    print()

    prev_samples = None
    flat_ticks = 0
    ever_flowed = False
    try:
        while True:
            now = datetime.now(timezone.utc)
            entry = {
                "timestamp": now.isoformat(),
                "elapsed_min": round((now - start_time).total_seconds() / 60, 1),
                "rss_mb": get_rss_mb(args.process_name),
                "cpu_pct": get_cpu_pct(args.process_name),
                "free_disk_gb": get_free_disk_gb(),
                "ble_connected": check_ble_connected(args.process_name),
                "samples_received": count_samples_csv(night_dir),
                "recording_size_mb": round(get_recording_size_mb(night_dir), 1),
                "fsm_state": get_app_state(night_dir),
                "packet_loss": None,  # populated if app writes it
                "osc_queue_depth": None,  # populated if app writes it
                "telemetry_git_sha": git_sha,
            }

            # Zero-throughput watchdog: catch the state that ran blind for 22h
            # on night-2026-07-18 — telemetry alive but no EEG being written,
            # whether because no recording session started or a live one stalled.
            # Un-gated from the old `samples > 0` guard (which could never fire
            # when the symlink pointed at a stale, non-growing session) and no
            # longer keyed on the ble_connected proxy. Complements the in-app
            # stream-stall watchdog (AppViewModel.nextOrStall), which only guards
            # an ACTIVE stream; this is the out-of-band observer that catches
            # "app up but not recording."
            samples = entry["samples_received"]
            flat_ticks, ever_flowed, failed, reason = evaluate_capture_health(
                prev_samples, samples, entry["elapsed_min"], ever_flowed, flat_ticks,
                warmup_min=args.warmup_min, stall_ticks=args.stall_ticks)
            prev_samples = samples
            entry["recording_stalled"] = failed
            entry["stall_reason"] = reason

            with open(metrics_path, "a") as f:
                f.write(json.dumps(entry, default=str) + "\n")

            # Console summary
            print(f"  [{entry['elapsed_min']:6.1f}m] "
                  f"RSS={_fmt(entry['rss_mb'], 7, 1)}MB "
                  f"CPU={_fmt(entry['cpu_pct'], 5, 1)}% "
                  f"Disk={_fmt(entry['free_disk_gb'], 5, 1)}GB "
                  f"App={'Y' if entry['ble_connected'] else 'N'} "
                  f"Samples={entry['samples_received']:>8d} "
                  f"Rec={entry['recording_size_mb']:>7.1f}MB "
                  f"FSM={entry['fsm_state']}")

            if failed:
                if args.no_abort:
                    print(f"  ⚠ STALL ({reason}): no new EEG samples for {flat_ticks} ticks "
                          f"(~{flat_ticks * args.interval}s) — recording is dead (log-only mode).")
                    flat_ticks = 0  # re-arm so it can flag again later
                else:
                    abort_capture(night_dir, reason, entry, flat_ticks, args.interval, metrics_path)
                    return

            time.sleep(args.interval)

    except KeyboardInterrupt:
        elapsed = (datetime.now(timezone.utc) - start_time).total_seconds() / 60
        print(f"\nStopped after {elapsed:.1f} minutes. Metrics in {metrics_path}")


if __name__ == "__main__":
    main()