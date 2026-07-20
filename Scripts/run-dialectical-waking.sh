#!/usr/bin/env bash
#
# run-dialectical-waking.sh — reproducible live Focused+Dialectical (WAKING) run
# on the Muse S. The first rung of the co-development mode ladder
# (Mirror → Focused+Dialectical → Reflective → Contemplative → … sleep modes).
#
# Builds --with-brainflow if the current binary isn't BrainFlow-linked, then
# launches the app with the hypnagogic dialectical loop auto-started (via the
# opt-in NEURALCOMPOSE_HYPNAGOGIC_AUTOSTART override) and local turn logging on,
# so the session produces dialectic-turns-<day>.jsonl for the session seed.
#
# The mic/speech authorization prompt and the red cloud-egress banner STILL gate
# the run — this override only flips the same opt-in the in-app UI toggle would.
#
#   ./Scripts/run-dialectical-waking.sh [mode]   # mode: focused|reflective|contemplative (default reflective)
#
# ⚠️ CLOUD EGRESS: dialectical mode makes TWO `claude` (Sonnet 5) calls per turn;
#    only transcript TEXT leaves the machine (audio + STT stay on-device). Opt-in,
#    disclosed in the banner, nothing persisted beyond the local turn log.
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

MODE="${1:-reflective}"
case "$MODE" in
    focused|reflective|contemplative) ;;
    *) echo "error: mode must be focused|reflective|contemplative (got '$MODE')" >&2; exit 2 ;;
esac

# Live EEG → SpectralGloss needs a BrainFlow-linked binary; a stub build silently
# falls back to the synthetic stream (gloss then stays neutral 0.5, no EEG bias).
if ! otool -L .build/debug/NeuralCompose 2>/dev/null | grep -q "libBoardController"; then
    echo "→ current binary is not BrainFlow-linked; building --with-brainflow…"
    ./Scripts/build.sh --with-brainflow
fi

export NEURALCOMPOSE_BOARD_PROFILE="${NEURALCOMPOSE_BOARD_PROFILE:-muses}"
export NEURALCOMPOSE_HYPNAGOGIC_AUTOSTART="${MODE}"
export NEURALCOMPOSE_INTERACTION_LOG=1

echo "→ live dialectical/waking run — mode=${MODE}, board=${NEURALCOMPOSE_BOARD_PROFILE}"
echo "  telemetry → ~/Documents/NeuralCompose/InteractionLogs/dialectic-turns-$(date +%Y-%m-%d).jsonl"
echo "  ⚠️ two Sonnet-5 cloud calls/turn while active (text only); grant mic + Bluetooth when prompted."
echo ""

exec "$REPO_ROOT/Scripts/run-muse-s.sh"
