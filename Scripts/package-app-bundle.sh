#!/usr/bin/env bash
#
# package-app-bundle.sh — wrap the SwiftPM-built NeuralCompose executable in
# a minimal .app bundle so macOS TCC can find NSBluetoothAlwaysUsageDescription
# / NSMicrophoneUsageDescription / NSSpeechRecognitionUsageDescription.
#
# Why this exists: Info.plist is intentionally NOT a SwiftPM resource (see
# CLAUDE.md) because SwiftPM forbids a top-level Info.plist for executable
# targets. That's fine for synthetic/stub runs, but any capability gated by
# TCC (Bluetooth, mic, speech) needs a bundle Info.plist to exist at all —
# without one, TCC doesn't just deny the request, it SIGABRTs the process
# (__TCC_CRASHING_DUE_TO_PRIVACY_VIOLATION__). Confirmed by hand: the bare
# `.build/debug/NeuralCompose` binary crashes the instant BrainFlow's BLE
# scan touches CoreBluetooth.
#
# Usage:
#   ./Scripts/package-app-bundle.sh                # wraps .build/debug/NeuralCompose
#   ./Scripts/package-app-bundle.sh --release       # wraps .build/release/NeuralCompose
#
# Prints the bundle path on success. Run the bundled binary directly (not
# via `open`) so environment variables (DYLD_LIBRARY_PATH, NEURALCOMPOSE_*)
# still reach the process:
#   DYLD_LIBRARY_PATH=... NEURALCOMPOSE_BOARD_PROFILE=muses \
#       .build/NeuralCompose.app/Contents/MacOS/NeuralCompose
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

CONFIG="debug"
for arg in "$@"; do
    case "$arg" in
        --release) CONFIG="release" ;;
        --debug)   CONFIG="debug" ;;
        -h|--help)
            grep '^#' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) echo "Unknown argument: $arg" >&2; exit 1 ;;
    esac
done

BIN="$REPO_ROOT/.build/$CONFIG/NeuralCompose"
if [[ ! -x "$BIN" ]]; then
    echo "Error: $BIN not found. Build first (./Scripts/build.sh [--with-brainflow] [$([[ $CONFIG == release ]] && echo --release)])." >&2
    exit 1
fi

APP="$REPO_ROOT/.build/NeuralCompose.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/NeuralCompose"
cp "$REPO_ROOT/Sources/NeuralComposeApp/Resources/Info.plist" "$APP/Contents/Info.plist"

# Any dylibs already sitting next to the bare binary (build.sh copies
# BrainFlow's runtime libs into .build/<config>/) need to travel into the
# bundle too, since callers will point DYLD_LIBRARY_PATH at BrainFlow's
# original compiled/ dir regardless — this copy is just for parity with
# the bare-binary layout, not strictly required when DYLD_LIBRARY_PATH is
# set by the caller (see run-muse-s.sh).
shopt -s nullglob
for dylib in "$REPO_ROOT/.build/$CONFIG"/*.dylib; do
    cp "$dylib" "$APP/Contents/MacOS/"
done
shopt -u nullglob

# ── MLX GPU resources for the on-device spectral estimator ────────────────
# SpectralStateEstimatorFactory runs a SpectralProbe subprocess
# (SubprocessProbe.locateSiblingBinary → next to the app executable) and then
# loads an MLX model in-process. Both need MLX's compiled Metal kernels
# (mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib). Plain `swift
# build` compiles the .metal sources but cannot run `metallib` to package them
# (see build-xcode-mlx.sh / MODEL_SETUP.md §"Metal kernels"), so neither the
# probe binary nor the metallib lands in .build/<config> on its own. Without
# both, the factory falls back to the stub estimator and every EEG→SpectralState
# gloss is dead (glossScalar pinned at the neutral 0.5). Copy them in when
# available so a bundled *live* run gets the real MLX estimator.
if [[ -x "$REPO_ROOT/.build/$CONFIG/SpectralProbe" ]]; then
    cp "$REPO_ROOT/.build/$CONFIG/SpectralProbe" "$APP/Contents/MacOS/SpectralProbe"
fi
CMLX_SRC=""
for cand in \
    "$REPO_ROOT/.build/$CONFIG/mlx-swift_Cmlx.bundle" \
    "$REPO_ROOT/.build/xcode/Build/Products/Debug/mlx-swift_Cmlx.bundle" \
    "$REPO_ROOT/.build/xcode/Build/Products/Release/mlx-swift_Cmlx.bundle"; do
    if [[ -f "$cand/Contents/Resources/default.metallib" ]]; then CMLX_SRC="$cand"; break; fi
done
if [[ -n "$CMLX_SRC" ]]; then
    # A SwiftPM resource bundle belongs in Contents/Resources (not MacOS): that
    # is where codesign --deep seals it correctly and where Bundle.module's
    # accessor (Bundle.main.resourceURL) resolves it for both the app process
    # and the colocated SpectralProbe subprocess. Putting it in MacOS/ breaks
    # the signature ("code has no resources but signature indicates…").
    mkdir -p "$APP/Contents/Resources"
    rm -rf "$APP/Contents/Resources/mlx-swift_Cmlx.bundle"
    cp -R "$CMLX_SRC" "$APP/Contents/Resources/mlx-swift_Cmlx.bundle"
    echo "  + MLX metallib bundle → Contents/Resources from ${CMLX_SRC#"$REPO_ROOT"/}"
else
    echo "  ! no mlx-swift_Cmlx.bundle with a metallib found — spectral estimator will be STUB."
    echo "    (run ./Scripts/build-xcode-mlx.sh once to build default.metallib.)"
fi

# Ad-hoc sign so Gatekeeper/TCC treat this as a coherent, launchable bundle
# instead of a loose tree of files copied around after the real build.
codesign --force --deep -s - "$APP" >/dev/null

echo "Bundled: $APP"
