#!/usr/bin/env bash
#
# run-synthetic.sh — launch NeuralCompose with the EEG stream of your choice.
#
# Usage:
#   ./Scripts/run-synthetic.sh                                 # synthetic stream, mock classifier, stub predictor
#   ./Scripts/run-synthetic.sh --profile museS                 # try real Muse S over BrainFlow
#   ./Scripts/run-synthetic.sh --profile playback --recording Recordings/foo.csv
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

PROFILE="synthetic"
RECORDING=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --profile)   PROFILE="$2"; shift 2 ;;
        --recording) RECORDING="$2"; shift 2 ;;
        -h|--help)
            grep '^#' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *)
            echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

export NEURALCOMPOSE_BOARD_PROFILE="$PROFILE"
if [[ -n "$RECORDING" ]]; then
    export NEURALCOMPOSE_PLAYBACK_PATH="$RECORDING"
fi

exec swift run -c debug NeuralCompose
