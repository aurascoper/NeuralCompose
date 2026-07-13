#!/usr/bin/env bash
#
# build-xcode-mlx.sh — build NeuralCompose with `xcodebuild` so MLX's Metal
# shaders compile against the real Xcode toolchain.
#
# Why: SwiftPM's CLI build (./Scripts/build.sh) is fine for everything except
# the MLX GPU path. MLX-Swift ships Metal shader sources that `swift build`
# can compile *syntactically* but cannot package into a Metal library — only
# `xcodebuild` (or Xcode itself) drives `metal` + `metallib` properly. Once
# you actually wire up `MLXNextWordPredictor` against the live MLX API, build
# with this script for any test that exercises the GPU.
#
# Usage:
#   ./Scripts/build-xcode-mlx.sh                # Debug build, no smoke test
#   ./Scripts/build-xcode-mlx.sh --release      # Release configuration
#   ./Scripts/build-xcode-mlx.sh --smoke        # Build + run a tiny MLX
#                                                 smoke test that confirms
#                                                 a Metal library is loadable
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

CONFIG="Debug"
RUN_SMOKE=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --release) CONFIG="Release"; shift ;;
        --debug)   CONFIG="Debug"; shift ;;
        --smoke)   RUN_SMOKE=1; shift ;;
        -h|--help)
            grep '^#' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

if ! xcode-select -p >/dev/null 2>&1; then
    echo "Xcode is required (xcode-select -p returns nothing)." >&2
    echo "Install Xcode from the App Store and run:" >&2
    echo "  sudo xcode-select -s /Applications/Xcode.app/Contents/Developer" >&2
    exit 1
fi

# `xcodebuild -scheme` works on SwiftPM packages directly in modern Xcode.
# The product is the executable target.
#
# We honor xcbeautify *if it's installed*, but never swallow xcodebuild's
# exit status — `set -o pipefail` plus the explicit conditional ensure that
# a failed build aborts this script instead of letting us fall through to
# `Built: $BIN` against a stale binary.
set -o pipefail
echo "xcodebuild -scheme NeuralCompose -configuration $CONFIG"
if command -v xcbeautify >/dev/null 2>&1; then
    xcodebuild \
        -scheme NeuralCompose \
        -configuration "$CONFIG" \
        -destination 'platform=macOS' \
        -derivedDataPath "$REPO_ROOT/.build/xcode" \
        build | xcbeautify
else
    xcodebuild \
        -scheme NeuralCompose \
        -configuration "$CONFIG" \
        -destination 'platform=macOS' \
        -derivedDataPath "$REPO_ROOT/.build/xcode" \
        build
fi

BIN="$REPO_ROOT/.build/xcode/Build/Products/${CONFIG}/NeuralCompose"
if [[ ! -x "$BIN" ]]; then
    # Fall back to scanning DerivedData if xcodebuild laid things out
    # differently — this happens with macOS schemes that use Frameworks/.
    BIN="$(find "$REPO_ROOT/.build/xcode" -type f -name NeuralCompose -perm +111 | head -n 1)"
fi
if [[ -z "${BIN:-}" || ! -x "$BIN" ]]; then
    echo "Could not locate the built NeuralCompose binary." >&2
    exit 1
fi
echo "Built: $BIN"

if [[ "$RUN_SMOKE" -eq 1 ]]; then
    echo "Running MLX smoke test (CTRL-C after a few seconds)..."
    # Use the synthetic profile so the smoke test exercises the GPU path
    # (once you've wired up real MLX in BCILLM) without needing a Muse.
    NEURALCOMPOSE_BOARD_PROFILE=synthetic exec "$BIN"
fi
