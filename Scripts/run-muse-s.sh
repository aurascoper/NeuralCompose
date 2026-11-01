#!/usr/bin/env bash
#
# run-muse-s.sh - native Muse S BLE smoke test runner.
#
# Usage:
#   ./Scripts/run-muse-s.sh                                    # broadest scan
#   NEURALCOMPOSE_MUSE_SERIAL_NUMBER="MUSE-XXXX-XXXX-XXXX" \
#   ./Scripts/run-muse-s.sh                                    # scan by serial
#   NEURALCOMPOSE_MUSE_MAC="AA:BB:CC:DD:EE:FF" \
#   ./Scripts/run-muse-s.sh                                    # scan by MAC
#
# Launches via `open` against a bundled .app (see package-app-bundle.sh),
# never the bare .build/debug/NeuralCompose executable directly - a bare
# SwiftPM executable has no bundle Info.plist, so macOS TCC SIGABRTs the
# process the instant BrainFlow's BLE scan touches CoreBluetooth instead
# of prompting for Bluetooth access (confirmed by hand, 2026-07-11).
# `open` also gives correct LaunchServices window/activation behavior
# that a direct exec doesn't - a bare-exec'd bundle registers with the
# window server but never creates a window.
#

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

BF="${BRAINFLOW_ROOT:-$HOME/Developer/brainflow}"
if [[ ! -d "$BF/compiled" ]]; then
    echo "Error: BrainFlow not found at $BF. Set BRAINFLOW_ROOT or install to ~/Developer/brainflow." >&2
    exit 1
fi

# Ensure the app is built and linked against BrainFlow's libBoardController
# (not a stub build from a bare `swift build`).
if [[ ! -f .build/debug/NeuralCompose ]] || ! otool -L .build/debug/NeuralCompose | grep -q libBoardController; then
    echo "Building NeuralCompose with BrainFlow linkage..."
    "$REPO_ROOT/Scripts/build.sh" --with-brainflow
fi

if ! otool -L .build/debug/NeuralCompose | grep -q libBoardController; then
    echo "Error: .build/debug/NeuralCompose is not linked against libBoardController. Run './Scripts/build.sh --with-brainflow' first." >&2
    exit 1
fi

"$REPO_ROOT/Scripts/package-app-bundle.sh"

BOARD_PROFILE="${NEURALCOMPOSE_BOARD_PROFILE:-muses}"

ENV_ARGS=(--env "NEURALCOMPOSE_BOARD_PROFILE=$BOARD_PROFILE")
if [[ -n "${NEURALCOMPOSE_MUSE_SERIAL_NUMBER:-}" ]]; then
    ENV_ARGS+=(--env "NEURALCOMPOSE_MUSE_SERIAL_NUMBER=$NEURALCOMPOSE_MUSE_SERIAL_NUMBER")
fi
if [[ -n "${NEURALCOMPOSE_MUSE_SERIAL:-}" ]]; then
    ENV_ARGS+=(--env "NEURALCOMPOSE_MUSE_SERIAL=$NEURALCOMPOSE_MUSE_SERIAL")
fi
if [[ -n "${NEURALCOMPOSE_MUSE_MAC:-}" ]]; then
    ENV_ARGS+=(--env "NEURALCOMPOSE_MUSE_MAC=$NEURALCOMPOSE_MUSE_MAC")
fi
if [[ -n "${NEURALCOMPOSE_MUSE_DISCOVERY_TIMEOUT:-}" ]]; then
    ENV_ARGS+=(--env "NEURALCOMPOSE_MUSE_DISCOVERY_TIMEOUT=$NEURALCOMPOSE_MUSE_DISCOVERY_TIMEOUT")
fi
if [[ -n "${NEURALCOMPOSE_BRAINFLOW_OTHER_INFO:-}" ]]; then
    ENV_ARGS+=(--env "NEURALCOMPOSE_BRAINFLOW_OTHER_INFO=$NEURALCOMPOSE_BRAINFLOW_OTHER_INFO")
fi
# Opt-in co-dev-loop launch overrides (default unset -> not forwarded, no change
# in behaviour). See run-dialectical-waking.sh and AppViewModel autostart.
if [[ -n "${NEURALCOMPOSE_HYPNAGOGIC_AUTOSTART:-}" ]]; then
    ENV_ARGS+=(--env "NEURALCOMPOSE_HYPNAGOGIC_AUTOSTART=$NEURALCOMPOSE_HYPNAGOGIC_AUTOSTART")
fi
if [[ -n "${NEURALCOMPOSE_INTERACTION_LOG:-}" ]]; then
    ENV_ARGS+=(--env "NEURALCOMPOSE_INTERACTION_LOG=$NEURALCOMPOSE_INTERACTION_LOG")
fi

echo "Running NeuralCompose with native Muse S BLE..."
echo "  BOARD_PROFILE: $BOARD_PROFILE"
if [[ -n "${NEURALCOMPOSE_MUSE_SERIAL_NUMBER:-}" ]]; then
    echo "  SERIAL_NUMBER: $NEURALCOMPOSE_MUSE_SERIAL_NUMBER"
fi
if [[ -n "${NEURALCOMPOSE_MUSE_SERIAL:-}" ]]; then
    echo "  SERIAL_PORT: $NEURALCOMPOSE_MUSE_SERIAL"
fi
if [[ -n "${NEURALCOMPOSE_MUSE_MAC:-}" ]]; then
    echo "  MAC_ADDRESS: $NEURALCOMPOSE_MUSE_MAC"
fi
if [[ -n "${NEURALCOMPOSE_MUSE_DISCOVERY_TIMEOUT:-}" ]]; then
    echo "  DISCOVERY_TIMEOUT: $NEURALCOMPOSE_MUSE_DISCOVERY_TIMEOUT"
fi
if [[ -n "${NEURALCOMPOSE_BRAINFLOW_OTHER_INFO:-}" ]]; then
    echo "  BRAINFLOW_OTHER_INFO: $NEURALCOMPOSE_BRAINFLOW_OTHER_INFO"
fi
if [[ -n "${NEURALCOMPOSE_HYPNAGOGIC_AUTOSTART:-}" ]]; then
    echo "  HYPNAGOGIC_AUTOSTART: $NEURALCOMPOSE_HYPNAGOGIC_AUTOSTART (cloud egress while active)"
fi
echo ""

open -n "${ENV_ARGS[@]}" "$REPO_ROOT/.build/NeuralCompose.app"
