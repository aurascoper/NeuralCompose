#!/usr/bin/env bash
#
# run-muse-s.sh — native Muse S BLE smoke test runner.
#
# Usage:
#   ./Scripts/run-muse-s.sh                                    # broadest scan
#   NEURALCOMPOSE_MUSE_SERIAL_NUMBER="MUSE-XXXX-XXXX-XXXX" \
#   ./Scripts/run-muse-s.sh                                    # scan by serial
#   NEURALCOMPOSE_MUSE_MAC="AA:BB:CC:DD:EE:FF" \
#   ./Scripts/run-muse-s.sh                                    # scan by MAC
#

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

# Ensure the app is built.
if [[ ! -f .build/debug/NeuralCompose ]]; then
    echo "Error: .build/debug/NeuralCompose not found. Run './Scripts/build.sh --with-brainflow' first." >&2
    exit 1
fi

BF="${BRAINFLOW_ROOT:-$HOME/Developer/brainflow}"
if [[ ! -d "$BF/compiled" ]]; then
    echo "Error: BrainFlow not found at $BF. Set BRAINFLOW_ROOT or install to ~/Developer/brainflow." >&2
    exit 1
fi

export DYLD_LIBRARY_PATH="$BF/compiled:${DYLD_LIBRARY_PATH:-}"
export NEURALCOMPOSE_BOARD_PROFILE="${NEURALCOMPOSE_BOARD_PROFILE:-muses}"

echo "Running NeuralCompose with native Muse S BLE..."
echo "  BOARD_PROFILE: $NEURALCOMPOSE_BOARD_PROFILE"
if [[ -n "${NEURALCOMPOSE_MUSE_SERIAL_NUMBER:-}" ]]; then
    echo "  SERIAL_NUMBER: $NEURALCOMPOSE_MUSE_SERIAL_NUMBER"
fi
if [[ -n "${NEURALCOMPOSE_MUSE_MAC:-}" ]]; then
    echo "  MAC_ADDRESS: $NEURALCOMPOSE_MUSE_MAC"
fi
echo ""

exec .build/debug/NeuralCompose
