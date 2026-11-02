#!/usr/bin/env bash
#
# build.sh - build NeuralCompose with sensible defaults.
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

CAP_CONFIG="Debug"
if [[ "$CONFIG" == "release" ]]; then
    CAP_CONFIG="Release"
fi

LINK_FILE_LIST="$REPO_ROOT/.build/out/Intermediates.noindex/NeuralCompose.build/$CAP_CONFIG/NeuralCompose-p.build/Objects-normal/arm64/NeuralCompose.LinkFileList"
CMLX_OBJ="$REPO_ROOT/.build/out/Products/$CAP_CONFIG/Cmlx.o"
OUT_BIN="$REPO_ROOT/.build/out/Products/$CAP_CONFIG/NeuralCompose"

if [[ "$USE_BRAINFLOW" -eq 1 && -f "$LINK_FILE_LIST" && -f "$CMLX_OBJ" ]]; then
    echo "swift build --target BCIEEG ${ARGS[*]}"
    swift build --target BCIEEG "${ARGS[@]}"
    SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
    SWIFT_LIB_DIR="$(dirname "$(xcrun --find swiftc)")/../lib/swift/macosx"
    echo "Relinking $OUT_BIN with libBoardController.dylib..."
    xcrun clang++ -target arm64-apple-macosx14.0 -isysroot "$SDK_PATH" \
        -L"$REPO_ROOT/.build/out/Products/$CAP_CONFIG" \
        -L"$SWIFT_LIB_DIR" \
        -L"/usr/lib/swift" \
        -F"$REPO_ROOT/.build/out/Products/$CAP_CONFIG/PackageFrameworks" \
        -F"$SDK_PATH/System/Library/Frameworks" \
        "@$LINK_FILE_LIST" \
        -L"${BRAINFLOW_PATH}/compiled" -lBoardController \
        -lc++ -framework Accelerate -framework Metal -framework Foundation -framework AppKit \
        -framework SwiftUI -framework Combine -framework CoreBluetooth -framework AVFoundation \
        -framework Speech -framework CoreAudio -framework AudioToolbox \
        -Xlinker -rpath -Xlinker "$SWIFT_LIB_DIR" \
        -Xlinker -rpath -Xlinker "@executable_path" \
        -Xlinker -rpath -Xlinker "${BRAINFLOW_PATH}/compiled" \
        -o "$OUT_BIN"
    BUILD_EXIT=$?
else
    echo "swift build ${ARGS[*]}"
    swift build "${ARGS[@]}"
    BUILD_EXIT=$?
fi

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

