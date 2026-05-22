#!/bin/bash

# run-calibration.sh
#
# Builds NeuralCompose with BrainFlow and launches in calibration mode.
#
# Usage:
#   NEURALCOMPOSE_BOARD_PROFILE=muses ./Scripts/run-calibration.sh
#   NEURALCOMPOSE_BOARD_PROFILE=synthetic ./Scripts/run-calibration.sh
#
# Environment:
#   NEURALCOMPOSE_BOARD_PROFILE  Board to use (muses, museTwoNativeBLE, synthetic)
#   NEURALCOMPOSE_MUSE_MAC       MAC address of target Muse device (optional)
#   NEURALCOMPOSE_MUSE_SERIAL    Serial port for BLED112 dongle (optional)
#   NEURALCOMPOSE_MUSE_SERIAL_NUMBER   Serial number of Muse device (optional)

set -e

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PROJECT_DIR="$( dirname "$SCRIPT_DIR" )"

# Build with BrainFlow
echo "Building NeuralCompose with BrainFlow..."
cd "$PROJECT_DIR"
swift build -c debug

# Find the executable
EXECUTABLE="$PROJECT_DIR/.build/debug/NeuralCompose"

if [ ! -x "$EXECUTABLE" ]; then
    echo "Error: executable not found at $EXECUTABLE"
    exit 1
fi

# Set up environment for BrainFlow and launch
echo ""
echo "Launching NeuralCompose (Calibration Mode)"
echo "=========================================="
echo "Profile:     ${NEURALCOMPOSE_BOARD_PROFILE:-synthetic}"
echo "Recording:   ~/NeuralCompose/Recordings/"
echo ""
echo "Keyboard shortcuts (when Calibration panel is open):"
echo "  [r]   Rest (sticky)"
echo "  [j]   Jaw Clench (sticky)"
echo "  [x]   Artifact (sticky)"
echo "  [Esc] Clear sticky label"
echo "  [b]   Blink (2s event)"
echo "  [d]   Double Blink (3s event)"
echo "  [s]   Select (2s event)"
echo ""
echo "Protocol (5 min):"
echo "  1. 30s rest      [r]"
echo "  2. 20 jaw clenches  [j] x20"
echo "  3. 20 blinks     [b] x20"
echo "  4. 10 double blinks [d] x10"
echo "  5. 10 sustained clenches  [j] (hold 3-5s each)"
echo ""

# Export board profile if set
if [ -n "$NEURALCOMPOSE_BOARD_PROFILE" ]; then
    export NEURALCOMPOSE_BOARD_PROFILE
fi

# Run with library path setup for dynamic linking
export DYLD_LIBRARY_PATH="${PROJECT_DIR}/.build/debug:${DYLD_LIBRARY_PATH}"
"$EXECUTABLE"
