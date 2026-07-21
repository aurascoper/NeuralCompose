#!/usr/bin/env bash
# run-personal-voice.sh — launch the BUNDLED app with the user's on-device
# Personal Voice enabled (NEURALCOMPOSE_PERSONAL_VOICE=1).
#
# Why a dedicated script: Personal Voice requires (a) a real .app *bundle* so
# macOS can present the consent prompt (a bare `swift run` cannot — the prompt
# never appears and auth hangs), and (b) authorization that TCC pins to the
# app's code identity. We ad-hoc-package the bundle, then re-sign it with the
# STABLE local cert (Scripts/sign-app-local.sh) so the grant survives rebuilds
# instead of re-prompting each time (the cdhash changes on every ad-hoc rebuild).
#
# First run:  answer the "NeuralCompose would like to use your Personal Voice"
#             prompt → Allow. The app AWAITS authorization before resolving its
#             voice, so your Personal Voice is selected THIS launch (no re-run).
# Later runs: the grant is remembered (no prompt); the voice is selected at launch.
#
# Prereqs: System Settings → Accessibility → Personal Voice → a compiled voice +
# "Allow Apps to Request to Use" enabled.
#
# Usage: ./Scripts/run-personal-voice.sh [--profile synthetic|museS|playback]
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

PROFILE="synthetic"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --profile) PROFILE="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

echo "==> Building…"
swift build -c debug

echo "==> Packaging .app bundle…"
"$REPO_ROOT/Scripts/package-app-bundle.sh"

echo "==> Signing with stable local cert (so the Personal Voice grant persists)…"
if ! "$REPO_ROOT/Scripts/sign-app-local.sh"; then
  echo "    (stable signing failed — falling back to the ad-hoc signature;" >&2
  echo "     the Personal Voice grant will re-prompt on the next rebuild.)" >&2
fi

ENV_ARGS=(--env "NEURALCOMPOSE_PERSONAL_VOICE=1" --env "NEURALCOMPOSE_BOARD_PROFILE=$PROFILE")
# Optionally pin a specific voice id (otherwise the app auto-selects the Personal Voice).
if [[ -n "${NEURALCOMPOSE_VOICE_ID:-}" ]]; then
  ENV_ARGS+=(--env "NEURALCOMPOSE_VOICE_ID=$NEURALCOMPOSE_VOICE_ID")
  echo "  VOICE_ID (pinned): $NEURALCOMPOSE_VOICE_ID"
fi

echo "==> Launching (profile: $PROFILE, Personal Voice: ON)…"
echo "    When the Personal Voice prompt appears, click Allow — the voice activates this launch."
open -n "${ENV_ARGS[@]}" "$REPO_ROOT/.build/NeuralCompose.app"
