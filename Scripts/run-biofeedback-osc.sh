#!/usr/bin/env bash
#
# run-biofeedback-osc.sh - launch NeuralCompose with the biofeedback egress
# on (ADR-011, decision registry entry 10): Mind Monitor-compatible OSC and,
# optionally, a CoreMIDI virtual source, driven by whatever EEG source the
# app is configured for.
#
# What leaves the process is derived features only: per-channel band powers
# (Bels), per-channel contact quality (horseshoe), Track A blink and jaw
# clench events, and IMU readings when the transport has them. Raw EEG is
# never sent unless you pass --raw-eeg, and then only over OSC.
#
# Defaults send to 127.0.0.1:7000, which never leaves this Mac and is the
# port the Muse Port Max for Live device listens on. Any other --host is a
# LAN destination: OSC has no authentication or encryption, so keep that on
# a private network and expect the privacy indicator to show it in red.
#
# Usage:
#   ./Scripts/run-biofeedback-osc.sh                         # synthetic EEG -> OSC loopback 7000 (dry run, no hardware)
#   ./Scripts/run-biofeedback-osc.sh --board muses           # live Muse S over BLE
#   ./Scripts/run-biofeedback-osc.sh --board osc --port 7000 # Mind Monitor in (UDP 5000) -> features out (7000)
#   ./Scripts/run-biofeedback-osc.sh --host 192.168.1.20     # send to another machine on the LAN
#   ./Scripts/run-biofeedback-osc.sh --midi                  # also create the "NeuralCompose Biofeedback" MIDI source
#   ./Scripts/run-biofeedback-osc.sh --per-channel           # 4 floats per band instead of 1 average
#   ./Scripts/run-biofeedback-osc.sh --mappings ~/maps.json  # load a [BiofeedbackMapping] JSON set
#   ./Scripts/run-biofeedback-osc.sh --raw-eeg               # explicit raw /muse/eeg re-broadcast
#
# Then point your consumer at the port: Muse Port's UDP port field, Max's
# [udpreceive 7000], TouchDesigner's OSC In CHOP, SuperCollider's
# OSCFunc on NetAddr("127.0.0.1", 7000), or Bitwig's OSC input.
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

HOST="127.0.0.1"
PORT="7000"
BOARD="${NEURALCOMPOSE_BOARD_PROFILE:-synthetic}"
MIDI="0"
RAW="0"
PER_CHANNEL="0"
MAPPINGS=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --host)        HOST="$2"; shift 2 ;;
        --port)        PORT="$2"; shift 2 ;;
        --board)       BOARD="$2"; shift 2 ;;
        --midi)        MIDI="1"; shift ;;
        --raw-eeg)     RAW="1"; shift ;;
        --per-channel) PER_CHANNEL="1"; shift ;;
        --mappings)    MAPPINGS="$2"; shift 2 ;;
        -h|--help)
            grep '^#' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *)
            echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

export NEURALCOMPOSE_BOARD_PROFILE="$BOARD"
export NEURALCOMPOSE_BIOFEEDBACK_OSC="${HOST}:${PORT}"
export NEURALCOMPOSE_BIOFEEDBACK_MIDI="$MIDI"
export NEURALCOMPOSE_BIOFEEDBACK_RAW_EEG="$RAW"
export NEURALCOMPOSE_BIOFEEDBACK_PER_CHANNEL="$PER_CHANNEL"
if [[ -n "$MAPPINGS" ]]; then
    export NEURALCOMPOSE_BIOFEEDBACK_MAPPINGS="$MAPPINGS"
fi

TIER="loopback (never leaves this Mac)"
case "$HOST" in
    127.0.0.1|localhost|::1) ;;
    *) TIER="LAN host (unauthenticated UDP; private network only)" ;;
esac

echo "EEG source:        $BOARD"
echo "OSC egress:        ${HOST}:${PORT}  [$TIER]"
echo "MIDI egress:       $([[ "$MIDI" == "1" ]] && echo 'virtual source "NeuralCompose Biofeedback"' || echo off)"
echo "Band payload:      $([[ "$PER_CHANNEL" == "1" ]] && echo '4 floats per band (per channel)' || echo '1 float per band (average over healthy channels)')"
echo "Raw /muse/eeg:     $([[ "$RAW" == "1" ]] && echo 'ON (explicit)' || echo off)"
if [[ -n "$MAPPINGS" ]]; then echo "Mappings:          $MAPPINGS"; fi
echo "Derived features only; health-gated mappings per ADR-011."
echo

exec swift run -c debug NeuralCompose
