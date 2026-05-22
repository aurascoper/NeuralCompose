#!/usr/bin/env bash
#
# build.sh — build NeuralCompose with sensible defaults.
#
# Usage:
#   ./Scripts/build.sh                   # synthetic / stub build (no BrainFlow, no MLX weights)
#   ./Scripts/build.sh --release         # optimized build
#   ./Scripts/build.sh --with-brainflow  # link against an installed BrainFlow
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

CONFIG="debug"
USE_BRAINFLOW=0
BRAINFLOW_PATH=""

for arg in "$@"; do
    case "$arg" in
        --release)        CONFIG="release" ;;
        --debug)          CONFIG="debug" ;;
        --with-brainflow) USE_BRAINFLOW=1 ;;
        --brainflow-path=*)
            BRAINFLOW_PATH="${arg#*=}" ;;
        -h|--help)
            grep '^#' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *)
            echo "Unknown argument: $arg" >&2
            exit 1 ;;
    esac
done

ARGS=(-c "$CONFIG")

if [[ "$USE_BRAINFLOW" -eq 1 ]]; then
    # Determine BrainFlow path: explicit arg > ~/Developer/brainflow > homebrew
    if [[ -z "$BRAINFLOW_PATH" ]]; then
        if [[ -d "$HOME/Developer/brainflow" ]]; then
            BRAINFLOW_PATH="$HOME/Developer/brainflow"
        else
            BRAINFLOW_PATH="$(brew --prefix brainflow 2>/dev/null || echo /opt/homebrew)"
        fi
    fi

    BRAINFLOW_PATH="$(cd "$BRAINFLOW_PATH" 2>/dev/null && pwd)"
    if [[ ! -d "$BRAINFLOW_PATH" ]]; then
        echo "Error: BrainFlow not found at $BRAINFLOW_PATH" >&2
        exit 1
    fi

    # Include paths for board-controller C API
    ARGS+=(
        -Xcc "-DBCI_BRAINFLOW_AVAILABLE=1"
        -Xcc "-I${BRAINFLOW_PATH}/src/board_controller/inc"
        -Xcc "-I${BRAINFLOW_PATH}/src/utils/inc"
        -Xcc "-I${BRAINFLOW_PATH}/src/data_handler/inc"
        -Xcc "-I${BRAINFLOW_PATH}/third_party/json"
        -Xlinker "-L${BRAINFLOW_PATH}/compiled"
        -Xlinker "-lBoardController"
    )
    echo "Linking against BrainFlow at ${BRAINFLOW_PATH}"
fi

echo "swift build ${ARGS[*]}"
swift build "${ARGS[@]}"
BUILD_EXIT=$?

# Copy BrainFlow runtime dylibs next to binary for local testing
if [[ "$USE_BRAINFLOW" -eq 1 && "$BUILD_EXIT" -eq 0 ]]; then
    cp "$BRAINFLOW_PATH/compiled"/lib*.dylib ".build/$CONFIG/" 2>/dev/null || true
    # Also copy SimpleBLE dylibs if BrainFlow was built with BLE support
    find "$BRAINFLOW_PATH/build" \
        \( -name "libsimpleble*.dylib" -o -name "libsimpleble-c*.dylib" \) \
        -exec cp {} ".build/$CONFIG/" \; 2>/dev/null || true
    echo "Copied BrainFlow runtime libraries to .build/$CONFIG/"
fi

exit $BUILD_EXIT
