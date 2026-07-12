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
# Launches via `open` against a bundled .app (see package-app-bundle.sh),
# never the bare .build/debug/NeuralCompose executable directly — a bare
# SwiftPM executable has no bundle Info.plist, so macOS TCC SIGABRTs the
# process the instant BrainFlow's BLE scan touches CoreBluetooth instead
# of prompting for Bluetooth access (confirmed by hand, 2026-07-11).
# `open` also gives correct LaunchServices window/activation behavior
# that a direct exec doesn't — a bare-exec'd bundle registers with the
# window server but never creates a window.
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

"$REPO_ROOT/Scripts/package-app-bundle.sh"

BOARD_PROFILE="${NEURALCOMPOSE_BOARD_PROFILE:-muses}"

ENV_ARGS=(--env "NEURALCOMPOSE_BOARD_PROFILE=$BOARD_PROFILE")
if [[ -n "${NEURALCOMPOSE_MUSE_SERIAL_NUMBER:-}" ]]; then
    ENV_ARGS+=(--env "NEURALCOMPOSE_MUSE_SERIAL_NUMBER=$NEURALCOMPOSE_MUSE_SERIAL_NUMBER")
fi
if [[ -n "${NEURALCOMPOSE_MUSE_MAC:-}" ]]; then
    ENV_ARGS+=(--env "NEURALCOMPOSE_MUSE_MAC=$NEURALCOMPOSE_MUSE_MAC")
fi

echo "Running NeuralCompose with native Muse S BLE..."
echo "  BOARD_PROFILE: $BOARD_PROFILE"
if [[ -n "${NEURALCOMPOSE_MUSE_SERIAL_NUMBER:-}" ]]; then
    echo "  SERIAL_NUMBER: $NEURALCOMPOSE_MUSE_SERIAL_NUMBER"
fi
if [[ -n "${NEURALCOMPOSE_MUSE_MAC:-}" ]]; then
    echo "  MAC_ADDRESS: $NEURALCOMPOSE_MUSE_MAC"
fi
echo ""

open -n "${ENV_ARGS[@]}" "$REPO_ROOT/.build/NeuralCompose.app"
