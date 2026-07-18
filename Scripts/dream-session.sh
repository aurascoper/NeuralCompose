#!/usr/bin/env bash
#
# dream-session.sh — one-command EVENING ritual for a NeuralCompose capture night.
#
# Orchestrates the *support* scripts around a two-regime capture (10m focus /
# 10m drowsy active split + overnight sleep). It cannot drive the Muse or the
# app UI — you still wear the headset and start the app recording — but it
# chains preflight, keeps the Mac awake, backgrounds engineering telemetry, and
# runs the blink-tag cue helper. Tomorrow morning, run `/dream` from this repo
# for the review pass.
#
# Usage:
#   ./Scripts/dream-session.sh                                  # default protocol
#   ./Scripts/dream-session.sh --dry-run                        # rehearse: no waits, nothing detached
#   ./Scripts/dream-session.sh --segments focus:600 drowsy:600 sleep:0   # (must be last)
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RECORDINGS_BASE="${HOME}/Documents/NeuralCompose/Recordings"
PY="$REPO_ROOT/venv/bin/python3"; [[ -x "$PY" ]] || PY="python3"

DRY_RUN=0
NIGHT_DIR=""
SEGMENTS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run) DRY_RUN=1; shift ;;
        --night-dir) NIGHT_DIR="$2"; shift 2 ;;
        --segments) shift; SEGMENTS=("$@"); break ;;   # consumes the rest
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done
[[ -z "$NIGHT_DIR" ]] && NIGHT_DIR="${RECORDINGS_BASE}/night-$(date +%F)"

echo "=== NeuralCompose Dream Session ==="
echo "night dir: $NIGHT_DIR${DRY_RUN:+  (dry-run)}"
echo ""

# 1. Preflight (aborts on low disk).
echo "-- preflight --"
"$REPO_ROOT/Scripts/overnight-preflight.sh"
echo ""

mkdir -p "$NIGHT_DIR"
# Birth time of the night dir, used later to find the calibration_* dir this
# session's EEG actually landed in (CalibrationRecorder can't be told to
# write into NIGHT_DIR — see step 6). Captured now, before telemetry starts
# repeatedly touching files inside NIGHT_DIR and moving its mtime forward.
NIGHT_DIR_EPOCH=$(stat -f %B "$NIGHT_DIR")

# start_guarded <pidfile> <human-name> <command...>
#   backgrounds a command with nohup+disown, skipping if its pidfile is live.
#   In --dry-run it only prints what it would run.
start_guarded() {
    local pidfile="$1" name="$2"; shift 2
    if [[ -f "$pidfile" ]] && kill -0 "$(cat "$pidfile" 2>/dev/null)" 2>/dev/null; then
        echo "  $name already running (pid $(cat "$pidfile")) — skipping"
        return
    fi
    if [[ "$DRY_RUN" -eq 1 ]]; then
        echo "  [dry-run] would start $name: $*"
        return
    fi
    nohup "$@" > "${pidfile%.pid}.out" 2>&1 &
    local pid=$!
    disown "$pid" 2>/dev/null || true
    echo "$pid" > "$pidfile"
    echo "  started $name (pid $pid)"
}

# 2. Keep the Mac awake — a 6.5 h capture dies if the system sleeps. Safe to
#    start immediately: caffeinate doesn't care whether the app is running yet.
echo "-- keep-awake --"
start_guarded "$NIGHT_DIR/.caffeinate.pid" "caffeinate" caffeinate -dis
echo ""

# 3. The one thing the wrapper cannot do for you.
cat <<EOF
-- START THE RECORDING NOW --
  Put on the Muse S, then start the app and begin recording:
    (see Scripts/run-muse-s.sh; the wrapper can't drive BLE/UI). The app
    writes its own calibration_<timestamp>_<profile> session dir under
    $RECORDINGS_BASE — step 6 below links tonight's into $NIGHT_DIR/eeg_session.

EOF
if [[ "$DRY_RUN" -eq 0 ]]; then
    # `|| true` guards against non-interactive stdin (EOF makes `read` exit
    # non-zero, which set -e would otherwise treat as a hard failure here).
    read -r -p "Press Enter once the app shows it is recording... " _ || true
else
    echo "  [dry-run] would wait here for Enter"
fi
echo ""

# 4. Engineering telemetry for the night (system metrics 1/min). Started only
#    now, after the app is confirmed running — starting it earlier meant its
#    first tick always found no "NeuralCompose" process yet (rss_mb=None),
#    which used to crash the watcher (see overnight-telemetry.py's _fmt fix).
echo "-- telemetry --"
start_guarded "$NIGHT_DIR/.telemetry.pid" "telemetry" \
    "$PY" "$REPO_ROOT/Scripts/overnight-telemetry.py" --night-dir "$NIGHT_DIR"
echo ""

# 5. Blink-tag cue helper (foreground) — writes protocol-<ts>.json into the night dir.
echo "-- protocol cue helper --"
PROTOCOL_ARGS=(--out-dir "$NIGHT_DIR")
[[ ${#SEGMENTS[@]} -gt 0 ]] && PROTOCOL_ARGS+=(--segments "${SEGMENTS[@]}")
[[ "$DRY_RUN" -eq 1 ]] && PROTOCOL_ARGS+=(--dry-run)
"$PY" "$REPO_ROOT/Scripts/run-session-protocol.py" "${PROTOCOL_ARGS[@]}"
echo ""

# 6. Resolve which calibration_* dir this night's EEG actually landed in and
#    link it into NIGHT_DIR. Pick the largest (by disk usage) calibration_*
#    dir born at/after NIGHT_DIR — largest as a proxy for "the real overnight
#    session" rather than an aborted test recording.
echo "-- resolving EEG session dir --"
if [[ "$DRY_RUN" -eq 1 ]]; then
    echo "  [dry-run] would search for calibration_* dirs born at/after $NIGHT_DIR"
else
    EEG_DIR="" BEST_SIZE=-1
    for cand in "$RECORDINGS_BASE"/calibration_*; do
        [[ -d "$cand" ]] || continue
        cand_epoch=$(stat -f %B "$cand" 2>/dev/null) || continue
        (( cand_epoch < NIGHT_DIR_EPOCH )) && continue
        size=$(du -sk "$cand" 2>/dev/null | cut -f1)
        [[ -z "$size" ]] && size=0
        if (( size > BEST_SIZE )); then
            BEST_SIZE=$size
            EEG_DIR="$cand"
        fi
    done
    if [[ -n "$EEG_DIR" ]]; then
        ln -sfn "$EEG_DIR" "$NIGHT_DIR/eeg_session"
        echo "  linked $NIGHT_DIR/eeg_session -> $EEG_DIR"
    else
        echo "  ⚠ no calibration_* dir born after $NIGHT_DIR found — was the app recording ever started?"
    fi
fi

echo ""
echo "=== active split tagged. Telemetry + keep-awake keep running overnight. ==="
echo "Tomorrow, from $REPO_ROOT, run:  /dream neuralcompose"
[[ "$DRY_RUN" -eq 1 ]] && echo "(dry-run: nothing was backgrounded; no processes left running.)"
