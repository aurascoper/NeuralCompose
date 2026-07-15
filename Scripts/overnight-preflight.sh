#!/usr/bin/env bash
#
# overnight-preflight.sh — pre-flight checks before an overnight recording.
#
# Refuses to start if free disk < 10 GB. Warns if < 20 GB.
# Reports current disk, benchmark output size, and recording directory.
#
# Usage:
#   ./Scripts/overnight-preflight.sh
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RECORDINGS_DIR="${HOME}/Documents/NeuralCompose/Recordings"

echo "=== NeuralCompose Overnight Pre-Flight ==="
echo ""

# --- Disk space ---
AVAIL_GB=$(df -g / | tail -1 | awk '{print $4}')
echo "Free disk: ${AVAIL_GB} GB"

if [ "$AVAIL_GB" -lt 10 ]; then
    echo "FAIL: Free disk space below 10 GB threshold. Refusing to start."
    exit 1
fi

if [ "$AVAIL_GB" -lt 20 ]; then
    echo "WARNING: Free disk space below 20 GB. Proceed with caution."
fi

echo ""

# --- Benchmark output size ---
BENCH_SIZE=$(du -sh "${REPO_ROOT}/Evaluation/results" 2>/dev/null | awk '{print $1}')
echo "Evaluation/results: ${BENCH_SIZE:-0}"

# --- Recordings directory ---
if [ -d "$RECORDINGS_DIR" ]; then
    REC_COUNT=$(ls -1 "$RECORDINGS_DIR" 2>/dev/null | wc -l | tr -d ' ')
    REC_SIZE=$(du -sh "$RECORDINGS_DIR" 2>/dev/null | awk '{print $1}')
    echo "Recordings dir: ${RECORDINGS_DIR} (${REC_COUNT} items, ${REC_SIZE})"
else
    echo "Recordings dir: not found (will be created on first run)"
fi

echo ""

# --- Expected overnight storage ---
echo "Estimated overnight storage (4ch, 256Hz, float32):"
echo "  EEG data:    ~120 MB/night"
echo "  Telemetry:   ~1 MB/night (1/min JSON lines)"
echo "  Logs:        ~5-20 MB (depending on verbosity)"
echo "  Total:       well under 1 GB"
echo ""

# --- Check if benchmark is running ---
BENCH_PIDS=$(pgrep -f "EmbeddingBench\|GenerationEval\|run_stage_3" 2>/dev/null || true)
if [ -n "$BENCH_PIDS" ]; then
    echo "WARNING: Benchmark processes are running (PIDs: ${BENCH_PIDS})"
    echo "  Monitor disk usage — streaming pipeline may download/evict models."
    echo ""
fi

echo "Pre-flight OK. Ready for overnight run."
echo ""
echo "Next steps:"
echo "  1. Run the app with Muse S for 10 minutes (smoke test)"
echo "  2. Verify: BLE stable, logs writing, CPU/Memory stable"
echo "  3. Stop the app, replay the 10-min recording"
echo "  4. If replay is deterministic, start the overnight run"
echo "  5. Start telemetry: python3 Scripts/overnight-telemetry.py &"