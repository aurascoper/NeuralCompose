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

    # Summary
    print(f"## Summary")
    if metrics:
        rss_values = [m.get("rss_mb") for m in metrics if m.get("rss_mb") is not None]
        all_good = (
            all(m.get("ble_connected") for m in metrics[-10:]) and
            not exceptions and
            (len(rss_values) < 10 or
             (len(rss_values) > 10 and
              (sum(rss_values[len(rss_values)//2:]) / (len(rss_values) - len(rss_values)//2)) /
              (sum(rss_values[:len(rss_values)//2]) / (len(rss_values)//2)) < 1.2))
            if rss_values else True
        )
        if all_good:
            print(f"  ✓ Session looks healthy. Ready for analysis.")
        else:
            print(f"  ⚠ Issues detected. Review the sections above before proceeding.")
    print()
    print(f"Full telemetry: {night_dir / 'metrics.jsonl'}")


if __name__ == "__main__":
    main()