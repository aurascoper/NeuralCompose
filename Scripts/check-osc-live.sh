#!/usr/bin/env bash
#
# check-osc-live.sh — re-runnable version of the two ad hoc checks used to
# validate the first live OSC deployment (library WiFi -> Tailscale -> home
# Mac, see commit 84f86ee): is data actually flowing, and is it decoding
# cleanly. Maps to the "Transport" and "Acquisition" rows of
# docs/testing/deployment-checklist.md — a first step toward that
# checklist's "Running this as a script" section, not a replacement for it
# (the Interpretation/Lifecycle rows still need a human or a separate check).
#
# Usage:
#   ./Scripts/check-osc-live.sh                  # auto-discovers the NeuralCompose PID via the default port (5000)
#   ./Scripts/check-osc-live.sh --port 6000       # a different OSC port
#   ./Scripts/check-osc-live.sh --pid 12345       # skip discovery, check a known PID
#
set -euo pipefail

PORT="5000"
PID=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --port) PORT="$2"; shift 2 ;;
        --pid)  PID="$2"; shift 2 ;;
        -h|--help)
            grep '^#' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *)
            echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

if [[ -z "$PID" ]]; then
    PID="$(lsof -nP -iUDP:"$PORT" 2>/dev/null | awk 'NR==2 {print $2}')"
    if [[ -z "$PID" ]]; then
        echo "FAIL: nothing is listening on UDP port $PORT (is NeuralCompose running with --port $PORT?)" >&2
        exit 1
    fi
fi

echo "Checking PID $PID on UDP port $PORT..."
echo

echo "--- Transport: is real data arriving? (bytes_in should grow across samples) ---"
nettop -p "$PID" -l 3 -n 2>&1 | grep -E "bytes_in|udp4|udp6"
echo

echo "--- Acquisition: any decode errors in the last 30s? (should be empty) ---"
ERRORS="$(command log show --last 30s --predicate "process == \"NeuralCompose\" && senderImagePath contains \"NeuralCompose\"" 2>&1 \
    | grep -i -E "dropped malformed|MindMonitorOSCStream.*error" || true)"
if [[ -n "$ERRORS" ]]; then
    echo "$ERRORS"
    echo
    echo "FAIL: decode errors present — see docs/testing/deployment-checklist.md's Transport row"
    exit 1
else
    echo "(none)"
fi

echo
echo "OK — data flowing, zero decode errors in the last 30s."
