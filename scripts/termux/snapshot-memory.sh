#!/usr/bin/env bash
set -euo pipefail

# ──────────────────────────────────────────────────────────────
# snapshot-memory.sh — record system memory state on the Pixel 8a
# without capturing private content.
#
# Writes to .runtime/neuralcompose/state/memory-snapshot-*.txt
# ──────────────────────────────────────────────────────────────

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
RUNTIME_DIR="$REPO_ROOT/.runtime/neuralcompose"
SNAPSHOT_FILE="$RUNTIME_DIR/state/memory-snapshot-$(date +%Y%m%d-%H%M%S).txt"

mkdir -p "$RUNTIME_DIR/state"

{
  echo "=== Memory Snapshot: $(date -Iseconds) ==="
  echo ""

  echo "--- /proc/meminfo ---"
  cat /proc/meminfo 2>/dev/null || echo "unavailable"

  echo ""
  echo "--- Top processes by RSS ---"
  ps aux --sort=-%mem 2>/dev/null | head -20 || ps aux 2>/dev/null | head -20 || echo "unavailable"

  echo ""
  echo "--- Managed service RSS ---"
  for pid_file in "$RUNTIME_DIR/pids"/*.pid; do
    [[ -f "$pid_file" ]] || continue
    name="$(basename "$pid_file" .pid)"
    pid="$(cat "$pid_file" 2>/dev/null)" || continue
    if kill -0 "$pid" 2>/dev/null; then
      rss="$(ps -p "$pid" -o rss= 2>/dev/null | awk '{printf "%.0f MB", $1/1024}')" || rss="?"
      cmd="$(ps -p "$pid" -o comm= 2>/dev/null)" || cmd="?"
      echo "  $name (PID $pid): $rss — $cmd"
    else
      echo "  $name: stale PID $pid"
    fi
  done

  echo ""
  echo "--- Termux processes ---"
  ps aux 2>/dev/null | grep -i "termux\|com.termux" | head -10 || echo "unavailable"

  echo ""
  echo "--- Available storage ---"
  df -h /data/data/com.termux/files/home 2>/dev/null || df -h / 2>/dev/null || echo "unavailable"

  echo ""
  echo "--- Thermal ---"
  cat /sys/class/thermal/thermal_zone*/temp 2>/dev/null | head -5 || echo "unavailable"

  echo ""
  echo "=== End ==="
} > "$SNAPSHOT_FILE"

echo "Snapshot written to $SNAPSHOT_FILE"
