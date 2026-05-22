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

for arg in "$@"; do
    case "$arg" in
        --release)        CONFIG="release" ;;
        --debug)          CONFIG="debug" ;;
        --with-brainflow) USE_BRAINFLOW=1 ;;
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
    BREW_PREFIX="$(brew --prefix 2>/dev/null || echo /opt/homebrew)"
    ARGS+=(
        -Xcc "-DBCI_BRAINFLOW_AVAILABLE=1"
        -Xcc "-I${BREW_PREFIX}/include"
        -Xlinker "-L${BREW_PREFIX}/lib"
        -Xlinker "-lBrainflow"
        -Xlinker "-lBoardController"
    )
    echo "Linking against BrainFlow at ${BREW_PREFIX}"
fi

echo "swift build ${ARGS[*]}"
exec swift build "${ARGS[@]}"
