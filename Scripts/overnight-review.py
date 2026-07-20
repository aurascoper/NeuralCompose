#!/usr/bin/env python3
"""
overnight-review.py — morning review of an overnight recording session.

Answers the engineering checklist:
  - Did the session run continuously?
  - Any BLE disconnects?
  - Any packet loss?
  - Any crashes?
  - Peak RSS?
  - CPU utilization?
  - Total storage written?
  - Number of hypothetical cues?
  - Longest uninterrupted recording?
  - Any exceptions?

Usage:
    python3 Scripts/overnight-review.py [--night-dir <dir>]

If --night-dir is not specified, uses the most recent night-* directory.
"""
import argparse
import json
import subprocess
import sys
from datetime import datetime
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
RECORDINGS_BASE = Path.home() / "Documents" / "NeuralCompose" / "Recordings"


def find_latest_night_dir():
    """Find the most recent night-YYYY-MM-DD directory."""
    if not RECORDINGS_BASE.exists():
        return None
    nights = sorted(RECORDINGS_BASE.glob("night-*"))
    return nights[-1] if nights else None


def find_eeg_session_dir(night_dir):
    """Resolve the calibration_* dir this night's EEG actually landed in.

    CalibrationRecorder always writes its own calibration_<ts>_<profile> dir
    directly under RECORDINGS_BASE — there is no code path that makes it
    write into night_dir itself. dream-session.sh links the session it finds
    into night_dir/eeg_session; prefer that. Fall back to searching
    RECORDINGS_BASE for calibration_* dirs born at/after night_dir (covers
    night dirs created before this link existed), picking the largest by
    disk usage as a proxy for "the real session" over an aborted test.
    """
    link = night_dir / "eeg_session"
    if link.exists():
        return link.resolve()
    if not RECORDINGS_BASE.exists():
        return None
    try:
        night_birth = night_dir.stat().st_birthtime
    except AttributeError:
        night_birth = night_dir.stat().st_ctime
    best_dir, best_size = None, -1
    for cand in RECORDINGS_BASE.glob("calibration_*"):
        if not cand.is_dir():
            continue
        try:
            cand_birth = getattr(cand.stat(), "st_birthtime", cand.stat().st_ctime)
        except OSError:
            continue
        if cand_birth < night_birth:
            continue
        size = sum(f.stat().st_size for f in cand.glob("*") if f.is_file())
        if size > best_size:
            best_size, best_dir = size, cand
    return best_dir


def eeg_csv_stats(csv_path):
    """Cheap row-count + time-span stats for an eeg.csv without loading it fully."""
    try:
        with open(csv_path, "rb") as f:
            f.readline()  # header
            first_data = f.readline()
            f.seek(0, 2)
            size = f.tell()
            back = min(size, 8192)
            f.seek(max(0, size - back))
            tail = f.read().decode(errors="ignore")
        last_line = next((ln for ln in reversed(tail.strip().split("\n")) if ln.strip()), None)
        if not first_data or not last_line:
            return None
        first_t = float(first_data.decode().split(",")[0])
        last_t = float(last_line.split(",")[0])
        result = subprocess.run(["wc", "-l", str(csv_path)], capture_output=True, text=True, timeout=10)
        n_rows = max(0, int(result.stdout.strip().split()[0]) - 1)
        return {"n_rows": n_rows, "span_s": last_t - first_t}
    except Exception:
        return None


def load_metrics(night_dir):
    """Load metrics.jsonl into a list of dicts."""
    metrics_path = night_dir / "metrics.jsonl"
    if not metrics_path.exists():
        return []
    entries = []
    with open(metrics_path) as f:
        for line in f:
            line = line.strip()
            if line:
                try:
                    entries.append(json.loads(line))
                except json.JSONDecodeError:
                    pass
    return entries


def load_cue_log(night_dir):
    """Load passive cue simulation log."""
    cue_path = night_dir / "cue_simulation.log"
    if not cue_path.exists():
        return []
    with open(cue_path) as f:
        return [line.strip() for line in f if line.strip()]


def load_exceptions(night_dir):
    """Check for crash logs or exception files."""
    exceptions = []
    for pattern in ["*.crash", "*.exception", "error.log", "crash.log"]:
        for f in night_dir.glob(pattern):
            exceptions.append(str(f))
    return exceptions


def get_git_sha():
    """Short git SHA of this repo, or None — to compare against the SHA a night's
    telemetry stamped, flagging runs pinned to code that predates a later fix."""
    try:
        repo_root = Path(__file__).resolve().parent.parent
        result = subprocess.run(
            ["git", "-C", str(repo_root), "rev-parse", "--short", "HEAD"],
            capture_output=True, text=True, timeout=5
        )
        return result.stdout.strip() or None
    except Exception:
        return None


def main():
    parser = argparse.ArgumentParser(description="Morning review of overnight recording")
    parser.add_argument("--night-dir", type=str, default=None)
    args = parser.parse_args()

    night_dir = Path(args.night_dir) if args.night_dir else find_latest_night_dir()
    if not night_dir or not night_dir.exists():
        print("No night recording directory found.")
        print(f"Looked in: {RECORDINGS_BASE}")
        sys.exit(1)

    print(f"=== Overnight Review: {night_dir.name} ===")
    print(f"Directory: {night_dir}")
    print()

    # Loud failure banner: the telemetry watchdog writes CAPTURE_FAILED.json when
    # it aborts a zero-throughput run. If present, the night failed by definition —
    # surface it before anything else so it can't read "healthy" below.
    failed_marker = night_dir / "CAPTURE_FAILED.json"
    capture_failed = None
    if failed_marker.exists():
        try:
            capture_failed = json.loads(failed_marker.read_text())
        except (OSError, json.JSONDecodeError):
            capture_failed = {"reason": "unknown", "detail": "(CAPTURE_FAILED.json unreadable)"}
        print(f"## ✗ CAPTURE FAILED")
        print(f"  Reason:   {capture_failed.get('reason', '?')}")
        print(f"  Detail:   {capture_failed.get('detail', '')}")
        print(f"  Failed:   {capture_failed.get('failed_at', '?')} "
              f"(after {capture_failed.get('elapsed_min', '?')} min)")
        print(f"  The watchdog aborted this run and released the machine — no usable capture.")
        print()

    metrics = load_metrics(night_dir)
    cues = load_cue_log(night_dir)
    exceptions = load_exceptions(night_dir)

    if not metrics:
        print("No telemetry data found (metrics.jsonl missing or empty).")
        print("Was the telemetry logger running?")
    else:
        # Session duration
        first_ts = metrics[0].get("timestamp", "?")
        last_ts = metrics[-1].get("timestamp", "?")
        elapsed_min = metrics[-1].get("elapsed_min", 0)
        print(f"## Session")
        print(f"  Start:          {first_ts}")
        print(f"  End:            {last_ts}")
        print(f"  Duration:       {elapsed_min:.1f} minutes ({elapsed_min/60:.1f} hours)")
        print()

        # Continuity — check for gaps > 2x interval
        intervals = []
        for i in range(1, len(metrics)):
            t1 = datetime.fromisoformat(metrics[i-1]["timestamp"].replace("Z", "+00:00"))
            t2 = datetime.fromisoformat(metrics[i]["timestamp"].replace("Z", "+00:00"))
            gap = (t2 - t1).total_seconds()
            intervals.append(gap)
        if intervals:
            max_gap = max(intervals)
            gaps_over_2min = sum(1 for g in intervals if g > 120)
            print(f"  Max gap:        {max_gap:.0f}s")
            print(f"  Gaps > 2min:    {gaps_over_2min}")
            if gaps_over_2min == 0 and max_gap < 120:
                print(f"  Continuity:     ✓ Uninterrupted")
            else:
                print(f"  Continuity:     ⚠ {gaps_over_2min} gaps detected")
        print()

        # BLE
        ble_values = [m.get("ble_connected") for m in metrics]
        ble_disconnects = sum(1 for i in range(1, len(ble_values))
                              if ble_values[i-1] and not ble_values[i])
        ble_connected_pct = sum(1 for v in ble_values if v) / len(ble_values) * 100 if ble_values else 0
        print(f"## BLE")
        print(f"  Connected:      {ble_connected_pct:.1f}% of samples")
        print(f"  Disconnects:    {ble_disconnects}")
        print()

        # Memory
        rss_values = [m.get("rss_mb") for m in metrics if m.get("rss_mb") is not None]
        if rss_values:
            print(f"## Memory")
            print(f"  Peak RSS:       {max(rss_values):.1f} MB")
            print(f"  Min RSS:       {min(rss_values):.1f} MB")
            print(f"  Final RSS:     {rss_values[-1]:.1f} MB")
            # Check for steady increase (memory leak)
            if len(rss_values) > 10:
                first_half = sum(rss_values[:len(rss_values)//2]) / (len(rss_values)//2)
                second_half = sum(rss_values[len(rss_values)//2:]) / (len(rss_values) - len(rss_values)//2)
                growth_pct = (second_half - first_half) / first_half * 100 if first_half > 0 else 0
                print(f"  Growth:        {growth_pct:+.1f}% (first half vs second half)")
                if growth_pct > 20:
                    print(f"                 ⚠ Possible memory leak")
                else:
                    print(f"                 ✓ Stable")
            print()

        # CPU
        cpu_values = [m.get("cpu_pct") for m in metrics if m.get("cpu_pct") is not None]
        if cpu_values:
            print(f"## CPU")
            print(f"  Peak:          {max(cpu_values):.1f}%")
            print(f"  Mean:          {sum(cpu_values)/len(cpu_values):.1f}%")
            print()

        # Disk
        disk_values = [m.get("free_disk_gb") for m in metrics if m.get("free_disk_gb") is not None]
        if disk_values:
            print(f"## Disk")
            print(f"  Start free:    {disk_values[0]:.1f} GB")
            print(f"  End free:      {disk_values[-1]:.1f} GB")
            print(f"  Consumed:      {disk_values[0] - disk_values[-1]:.1f} GB")
            print()

        # Samples
        if metrics[-1].get("samples_received"):
            total_samples = metrics[-1]["samples_received"]
            expected = elapsed_min * 60 * 256  # 256 Hz
            pct = total_samples / expected * 100 if expected > 0 else 0
            print(f"## Samples")
            print(f"  Received:      {total_samples:,}")
            print(f"  Expected:      {expected:,.0f} (256 Hz × {elapsed_min:.0f} min)")
            print(f"  Coverage:      {pct:.1f}%")
            if pct < 95:
                print(f"                 ⚠ Sample loss detected")
            else:
                print(f"                 ✓ Good coverage")
            print()

        # Recording size
        rec_sizes = [m.get("recording_size_mb") for m in metrics if m.get("recording_size_mb") is not None]
        if rec_sizes:
            print(f"## Storage")
            print(f"  Total written: {rec_sizes[-1]:.1f} MB")
            print()

    # EEG recording — separate from engineering telemetry. CalibrationRecorder
    # writes its own calibration_<ts>_<profile> dir, never into night_dir.
    eeg_dir = find_eeg_session_dir(night_dir)
    eeg_minutes = None
    print(f"## EEG Recording")
    if not eeg_dir:
        print(f"  ⚠ No EEG session found for this night (no {night_dir.name}/eeg_session link, "
              f"no calibration_* dir born at/after this night dir)")
        print(f"    Looked in: {RECORDINGS_BASE}")
    else:
        print(f"  Session dir:    {eeg_dir}")
        csvs = sorted(eeg_dir.glob("*.csv"), key=lambda f: f.stat().st_size if f.exists() else 0, reverse=True)
        if not csvs:
            print(f"  ⚠ Session dir has no CSV files")
        else:
            stats = eeg_csv_stats(csvs[0])
            if stats is None:
                print(f"  ⚠ Could not read {csvs[0].name}")
            else:
                eeg_minutes = stats["span_s"] / 60
                print(f"  EEG file:       {csvs[0].name}")
                print(f"  Rows:           {stats['n_rows']:,}")
                print(f"  Span:           {eeg_minutes:.1f} minutes ({stats['span_s'] / 3600:.2f} hours)")
                if eeg_minutes < 60:
                    print(f"                  ⚠ Under an hour — not a plausible overnight session")
    print()

    # Passive cue simulation
    print(f"## Passive Cue Simulation")
    print(f"  Hypothetical cues: {len(cues)}")
    if cues:
        print(f"  First:          {cues[0]}")
        print(f"  Last:           {cues[-1]}")
    print()

    # Exceptions
    print(f"## Exceptions")
    if exceptions:
        print(f"  ⚠ {len(exceptions)} exception/crash file(s) found:")
        for e in exceptions:
            print(f"    - {e}")
    else:
        print(f"  ✓ No crash logs or exception files found")
    print()

    # Summary — collect concrete issues rather than a single opaque boolean,
    # so a near-zero-duration or EEG-less night can't silently read "healthy".
    print(f"## Summary")
    issues = []
    if capture_failed:
        issues.append(f"CAPTURE FAILED ({capture_failed.get('reason', '?')}) — "
                      f"watchdog aborted this run; see CAPTURE_FAILED.json")
    if not metrics:
        issues.append("no telemetry data (metrics.jsonl missing or empty)")
    else:
        elapsed_min = metrics[-1].get("elapsed_min", 0)
        if elapsed_min < 30:
            issues.append(f"telemetry duration only {elapsed_min:.1f} min — watcher likely "
                          f"crashed or never ran overnight")
        if not all(m.get("ble_connected") for m in metrics[-10:]):
            issues.append("BLE not connected in the final samples")
        rss_values = [m.get("rss_mb") for m in metrics if m.get("rss_mb") is not None]
        if len(rss_values) > 10:
            first_half = sum(rss_values[:len(rss_values)//2]) / (len(rss_values)//2)
            second_half = sum(rss_values[len(rss_values)//2:]) / (len(rss_values) - len(rss_values)//2)
            if first_half > 0 and second_half / first_half >= 1.2:
                issues.append("possible memory leak (RSS grew >20% first half vs second half)")
        # Zero-throughput: telemetry never counted a single EEG sample. On
        # night-2026-07-18 this was true for all 1365 ticks yet the night read
        # "healthy" — the check that would have caught it.
        max_samples = max((m.get("samples_received") or 0) for m in metrics)
        if max_samples == 0:
            issues.append("telemetry counted 0 EEG samples for the entire run "
                          "(no recording session, or a blind/pre-fix telemetry sink)")
        # Stale-code guard: a long-running process pinned to code that predates a
        # later capture fix is the root enabler of the 7-18 blind run.
        shas = {m.get("telemetry_git_sha") for m in metrics if m.get("telemetry_git_sha")}
        current_sha = get_git_sha()
        if shas and current_sha and current_sha not in shas:
            issues.append(f"telemetry ran stale code (git {'/'.join(sorted(shas))}) — "
                          f"HEAD is now {current_sha}; a fix may not have been active during capture")
    if exceptions:
        issues.append(f"{len(exceptions)} crash/exception file(s) found")
    if not eeg_dir:
        issues.append("no EEG session found for this night")
    else:
        if eeg_minutes is not None and eeg_minutes < 60:
            issues.append(f"EEG span only {eeg_minutes:.1f} min — not a plausible overnight session")
        # Span mismatch: EEG far shorter than telemetry means the recorder stopped
        # (or the eeg_session symlink is stale) long before telemetry did — the
        # 81-min-vs-1367-min tell that read "healthy" on night-2026-07-18.
        telemetry_min = metrics[-1].get("elapsed_min", 0) if metrics else 0
        if eeg_minutes is not None and telemetry_min > 60 and eeg_minutes < 0.5 * telemetry_min:
            issues.append(f"EEG span ({eeg_minutes:.0f} min) far shorter than telemetry duration "
                          f"({telemetry_min:.0f} min) — recording stopped long before telemetry did "
                          f"(stale eeg_session symlink or dead recorder)")

    if not issues:
        print(f"  ✓ Session looks healthy. Ready for analysis.")
    else:
        print(f"  ⚠ Issues detected:")
        for issue in issues:
            print(f"    - {issue}")
    print()
    print(f"Full telemetry: {night_dir / 'metrics.jsonl'}")


if __name__ == "__main__":
    main()