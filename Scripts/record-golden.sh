#!/usr/bin/env bash
#
# record-golden.sh — capture the canonical "golden" reference EEG recording.
#
# Runs on macOS against a live Muse (this cannot run in the Linux sandbox —
# it needs Bluetooth and the built app). It launches NeuralCompose with the
# Muse S profile, then narrates a fixed, timed physiological protocol so the
# resulting recording is segmented on a known timeline. When you quit the
# app, it copies the newest recording into Recordings/golden/ (never
# overwriting) alongside a *.segments.csv describing the timeline.
#
# The golden recording is a regression fixture: every future visualization,
# health-threshold, or classifier change can be replayed against exactly the
# same data via PlaybackEEGStream, isolating software regressions from normal
# day-to-day EEG variation.
#
# Usage:
#   ./Scripts/build.sh --with-brainflow          # once, if not already built
#   NEURALCOMPOSE_MUSE_SERIAL_NUMBER="MUSE-XXXX-XXXX-XXXX" \
#     ./Scripts/record-golden.sh                 # optional: target by serial
#   ./Scripts/record-golden.sh                   # broadest scan
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

EXECUTABLE=".build/debug/NeuralCompose"
RECORDINGS_DIR="${HOME}/Documents/NeuralCompose/Recordings"
GOLDEN_DIR="${REPO_ROOT}/Recordings/golden"

# ── Preflight ────────────────────────────────────────────────────────────
if [[ ! -x "$EXECUTABLE" ]]; then
    echo "Error: $EXECUTABLE not found. Build first:" >&2
    echo "  ./Scripts/build.sh --with-brainflow" >&2
    exit 1
fi

BF="${BRAINFLOW_ROOT:-$HOME/Developer/brainflow}"
if [[ ! -d "$BF/compiled" ]]; then
    echo "Error: BrainFlow not found at $BF. Set BRAINFLOW_ROOT or install it." >&2
    exit 1
fi
export DYLD_LIBRARY_PATH="$BF/compiled:${DYLD_LIBRARY_PATH:-}"
export NEURALCOMPOSE_BOARD_PROFILE="${NEURALCOMPOSE_BOARD_PROFILE:-muses}"

mkdir -p "$GOLDEN_DIR"

# say(1) if available, else a no-op that just prints.
announce() {
    echo ">>> $*"
    if command -v say >/dev/null 2>&1; then say "$*" >/dev/null 2>&1 || true; fi
}

# Protocol: label + seconds. Order matters; the sidecar records cumulative
# offsets from protocol start (t=0 = the moment you press ENTER below).
SEGMENTS=(
    "eyes_open_rest:30"
    "eyes_closed_rest:30"
    "blinks_20:30"
    "jaw_clenches_10:20"
    "tp9_lift:10"
    "reseat_1:5"
    "af7_lift:10"
    "reseat_2:5"
    "af8_lift:10"
    "reseat_3:5"
    "tp10_lift:10"
    "reseat_4:5"
    "eyes_open_baseline:15"
)
# Per-channel electrode-lift segments (tp9_lift/af7_lift/af8_lift/tp10_lift)
# give analyze-eeg-session.py's per-channel quality table known-bad windows
# for every sensor, not just TP9 — validates the artifact/clipping detector
# against a deliberate disruption on each channel in turn, with a short
# reseat pause after each so the next lift starts from settled contact.

# Human cue shown/spoken at the start of each segment.
cue_for() {
    case "$1" in
        eyes_open_rest)      echo "Eyes open, relax, look at a fixed point." ;;
        eyes_closed_rest)    echo "Close your eyes and relax. Alpha should rise." ;;
        blinks_20)           echo "Eyes open. Blink deliberately, aiming for about twenty blinks total. Optional: press b each blink." ;;
        jaw_clenches_10)     echo "Clench your jaw firmly then relax, aiming for about ten clenches. Optional: press j." ;;
        tp9_lift)            echo "Lift the left ear sensor, T P 9, off your skin and hold it away." ;;
        af7_lift)            echo "Lift the left forehead sensor, A F 7, off your skin and hold it away." ;;
        af8_lift)            echo "Lift the right forehead sensor, A F 8, off your skin and hold it away." ;;
        tp10_lift)           echo "Lift the right ear sensor, T P 10, off your skin and hold it away." ;;
        reseat_1|reseat_2|reseat_3|reseat_4)
                              echo "Reseat the sensor and hold still while the signal settles." ;;
        eyes_open_baseline)  echo "Eyes open, relax. Final baseline." ;;
        *)                   echo "$1" ;;
    esac
}

echo "=============================================================="
echo " Golden recording — NeuralCompose"
echo "=============================================================="
echo "Profile: $NEURALCOMPOSE_BOARD_PROFILE"
echo "Total protocol length: ~$(( $(printf '%s\n' "${SEGMENTS[@]}" | cut -d: -f2 | paste -sd+ - | bc) ))s"
echo
echo "Launching the app in the background. Steps:"
echo "  1. Wait for the Muse to connect and live traces to appear."
echo "  2. In the app, enable Record so t=0 of the CSV ~ t=0 of this protocol."
echo "  3. Come back here and press ENTER to start the narrated protocol."
echo "  4. When it finishes, quit the app (Cmd+Q) to save the golden file."
echo

# Launch app in background so this terminal can narrate alongside it.
"$EXECUTABLE" &
APP_PID=$!
# If the script is interrupted, don't leave the app running.
trap '[[ -n "${APP_PID:-}" ]] && kill "$APP_PID" 2>/dev/null || true' EXIT

read -r -p "Press ENTER when recording is enabled and traces are live... "

PROTO_START=$(date +%s)
SIDECAR_TMP="$(mktemp)"
echo "label,start_s,end_s" > "$SIDECAR_TMP"

elapsed=0
for seg in "${SEGMENTS[@]}"; do
    label="${seg%%:*}"
    dur="${seg##*:}"
    start=$elapsed
    end=$(( elapsed + dur ))
    echo "${label},${start},${end}" >> "$SIDECAR_TMP"

    announce "$(cue_for "$label")"
    # Count down; announce the halfway and final 3 seconds.
    for (( t = dur; t > 0; t-- )); do
        printf "\r  [%-18s] %2ds remaining " "$label" "$t"
        if [[ $t -eq 3 ]]; then announce "three"; fi
        sleep 1
    done
    printf "\r  [%-18s] done%*s\n" "$label" 12 ""
    elapsed=$end
done

announce "Protocol complete. Quit the app to save the golden recording."
echo
echo "Protocol complete after ${elapsed}s. Now quit the app (Cmd+Q)."
echo "Waiting for the app to exit..."
wait "$APP_PID" 2>/dev/null || true
trap - EXIT

# ── Save the golden file ─────────────────────────────────────────────────
NEWEST="$(ls -t "$RECORDINGS_DIR"/*.csv 2>/dev/null | head -1 || true)"
if [[ -z "$NEWEST" ]]; then
    echo "Warning: no CSV found in $RECORDINGS_DIR. Was Record enabled?" >&2
    echo "Segment timeline saved to: $SIDECAR_TMP" >&2
    exit 1
fi

STAMP="$(date +%Y%m%d-%H%M%S)"
GOLDEN_CSV="${GOLDEN_DIR}/golden_${STAMP}.csv"
GOLDEN_SEG="${GOLDEN_DIR}/golden_${STAMP}.segments.csv"
cp "$NEWEST" "$GOLDEN_CSV"
mv "$SIDECAR_TMP" "$GOLDEN_SEG"

echo
echo "Golden recording saved:"
echo "  EEG:      $GOLDEN_CSV"
echo "  Segments: $GOLDEN_SEG"
echo
echo "Play it back with:"
echo "  ./Scripts/run-synthetic.sh --profile playback --recording \"$GOLDEN_CSV\""
echo
echo "Note: Recordings/ is gitignored (EEG never leaves the machine). If you"
echo "want this fixture in CI, decide deliberately how to share it — do not"
echo "blanket-commit Recordings/."
