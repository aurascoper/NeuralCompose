#!/usr/bin/env bash
#
# profile.sh — capture latency profile via Instruments Time Profiler.
#
# Requires Xcode command-line tools and an Apple-signed binary in .build/
# (a debug build is fine for these purposes; for production-style numbers
# build with --release).
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

CONFIG="release"
DURATION="20"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --debug)    CONFIG="debug"; shift ;;
        --duration) DURATION="$2"; shift 2 ;;
        -h|--help)
            grep '^#' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *)
            echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

./Scripts/build.sh --"$CONFIG"

BIN=".build/${CONFIG}/NeuralCompose"
if [[ ! -x "$BIN" ]]; then
    echo "Could not find binary at $BIN" >&2
    exit 1
fi

OUTPUT="profile-$(date +%Y%m%d-%H%M%S).trace"
echo "Recording $DURATION s of Time Profiler trace into $OUTPUT"

xcrun xctrace record \
    --template "Time Profiler" \
    --time-limit "${DURATION}s" \
    --launch "$BIN" \
    --output "$OUTPUT"

echo "Done. Open with:  open $OUTPUT"
