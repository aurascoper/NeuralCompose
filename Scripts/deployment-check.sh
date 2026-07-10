#!/usr/bin/env bash
#
# deployment-check.sh — runnable counterpart to
# docs/testing/deployment-checklist.md. Walks the same four sections
# (Transport / Acquisition / Interpretation / Lifecycle) and, for each row,
# either runs a real check against the live system or reports it as
# [MANUAL] — this does not pretend to automate what it can't. A row that
# needs eyes on the screen (the Muse's LED, the 2D/3D visuals, the privacy
# banner's text) stays [MANUAL]; a row that's really just "is data flowing
# and is it clean" becomes a real pass/fail.
#
# This absorbs check-osc-live.sh's two checks as part of the Transport and
# Acquisition sections (that script still works standalone for a quick
# OSC-only check; this one is the full checklist).
#
# Usage:
#   ./Scripts/deployment-check.sh                    # auto-detect transport, default port 5000
#   ./Scripts/deployment-check.sh --port 6000
#   ./Scripts/deployment-check.sh --pid 12345
#   ./Scripts/deployment-check.sh --transport osc|brainflow|auto
#   ./Scripts/deployment-check.sh --after-quit --port 5000   # verify the UDP port was actually released
#
# Exit code: non-zero if any automated check fails. [MANUAL] and [SKIP]
# rows never affect the exit code — they're not something this script can
# adjudicate — but they're always listed in the summary so nothing about
# "deployment looks healthy" is silently assumed.
#
set -uo pipefail  # no -e: one failed check shouldn't abort the rest of the walkthrough

PORT="5000"
PID=""
TRANSPORT="auto"
AFTER_QUIT=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --port)       PORT="$2"; shift 2 ;;
        --pid)        PID="$2"; shift 2 ;;
        --transport)  TRANSPORT="$2"; shift 2 ;;
        --after-quit) AFTER_QUIT=true; shift ;;
        -h|--help)
            grep '^#' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *)
            echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

PASS_COUNT=0
FAIL_COUNT=0
MANUAL_ITEMS=()
SKIP_ITEMS=()

pass() { PASS_COUNT=$((PASS_COUNT + 1)); echo "  [PASS] $1"; }
fail() { FAIL_COUNT=$((FAIL_COUNT + 1)); echo "  [FAIL] $1 — $2"; }
manual() { MANUAL_ITEMS+=("$1"); echo "  [MANUAL] $1"; }
skip() { SKIP_ITEMS+=("$1 ($2)"); echo "  [SKIP] $1 — $2"; }

# Converts a nettop byte value + unit ("14", "MiB") to an integer byte count.
bytes_to_int() {
    local value="$1" unit="$2"
    local mult=1
    case "$unit" in
        B) mult=1 ;;
        KiB) mult=1024 ;;
        MiB) mult=$((1024 * 1024)) ;;
        GiB) mult=$((1024 * 1024 * 1024)) ;;
        *) mult=1 ;;
    esac
    awk -v v="$value" -v m="$mult" 'BEGIN { printf "%d", v * m }'
}

if [[ -z "$PID" ]]; then
    PID="$(lsof -nP -iUDP:"$PORT" 2>/dev/null | awk 'NR==2 {print $2}')"
fi

if [[ "$TRANSPORT" == "auto" ]]; then
    if [[ -n "$PID" ]]; then
        TRANSPORT="osc"
    else
        TRANSPORT="brainflow"
    fi
fi

echo "NeuralCompose deployment check — transport: $TRANSPORT"
[[ -n "$PID" ]] && echo "PID: $PID, port: $PORT"
echo

# ---------------------------------------------------------------------------
echo "=== Transport ==="

if [[ "$AFTER_QUIT" == true ]]; then
    if lsof -nP -iUDP:"$PORT" >/dev/null 2>&1; then
        fail "UDP port released after quit" "port $PORT is still bound"
    else
        pass "UDP port released after quit (port $PORT is free)"
    fi
    echo
    echo "(--after-quit mode only checks port release; skipping the rest of the walkthrough)"
    exit $((FAIL_COUNT > 0 ? 1 : 0))
fi

manual "Muse paired over BLE (heartbeat LED pulse-orange, not fast-blinking)"

if [[ "$TRANSPORT" == "osc" ]]; then
    if [[ -z "$PID" ]]; then
        skip "OSC packets arriving" "nothing listening on UDP port $PORT"
        skip "Bound network interface is the expected VPN" "no listener to inspect"
    else
        LINE1="$(nettop -p "$PID" -l 1 -n 2>&1 | awk '/udp4.*<->/ && !/\*\.\*/{print; exit}')"
        sleep 1.5
        LINE2="$(nettop -p "$PID" -l 1 -n 2>&1 | awk '/udp4.*<->/ && !/\*\.\*/{print; exit}')"

        if [[ -z "$LINE1" || -z "$LINE2" ]]; then
            skip "OSC packets arriving" "no active udp4 connection yet (listener bound but no packets received)"
            skip "Bound network interface is the expected VPN" "no active connection to inspect"
        else
            B1=$(bytes_to_int "$(awk '{print $5}' <<<"$LINE1")" "$(awk '{print $6}' <<<"$LINE1")")
            B2=$(bytes_to_int "$(awk '{print $5}' <<<"$LINE2")" "$(awk '{print $6}' <<<"$LINE2")")
            if [[ "$B2" -gt "$B1" ]]; then
                pass "OSC packets arriving (bytes_in grew $B1 -> $B2 over ~1.5s)"
            else
                fail "OSC packets arriving" "bytes_in flat at $B1 over ~1.5s — stream may be idle/paused, or genuinely stalled"
            fi

            IFACE="$(awk '{print $4}' <<<"$LINE2")"
            if [[ "$IFACE" == utun* ]]; then
                pass "Bound network interface is the expected VPN ($IFACE)"
            else
                fail "Bound network interface is the expected VPN" "traffic is on '$IFACE', not a Tailscale utun* interface"
            fi
        fi
    fi
    manual "Privacy banner shows \"EEG: OSC Remote (network) (UDP $PORT · utun*)\""
else
    if command -v system_profiler >/dev/null 2>&1; then
        BT_INFO="$(system_profiler SPBluetoothDataType 2>/dev/null | grep -A5 -i "muse" || true)"
        if [[ -n "$BT_INFO" ]] && grep -qi "connected: yes" <<<"$BT_INFO"; then
            pass "Muse visible to macOS Bluetooth and connected"
        else
            fail "Muse visible to macOS Bluetooth and connected" "no connected Muse device found via system_profiler"
        fi
    else
        skip "Muse visible to macOS Bluetooth and connected" "system_profiler not available"
    fi
    manual "Privacy banner shows \"Live · Muse BLE/USB\", not \"Reconnecting…\""
fi

skip "Sample timestamps monotonic (no out-of-order, no duplicates)" \
    "pinned by testSampleTimestampsAreStrictlyMonotonic in MindMonitorOSCStreamTests.swift, not a live check — run 'swift test --filter testSampleTimestampsAreStrictlyMonotonic' to verify"

# ---------------------------------------------------------------------------
echo
echo "=== Acquisition ==="

manual "Channel health badges transition from \"no data\" to current values within 2s"
manual "2D plotter updates (raw EEG trace visible)"

if [[ "$TRANSPORT" == "osc" ]]; then
    ERRORS="$(command log show --last 30s --predicate 'process == "NeuralCompose"' 2>&1 \
        | grep -i -E "dropped malformed|MindMonitorOSCStream.*error" || true)"
    if [[ -n "$ERRORS" ]]; then
        fail "No dropped-packet warnings in the last 30s" "$(wc -l <<<"$ERRORS" | tr -d ' ') error line(s) found"
    else
        pass "No dropped-packet warnings in the last 30s"
    fi
else
    skip "No dropped-packet warnings in the last 30s" "no equivalent log pattern instrumented for BrainFlow yet"
fi

RECORDING_DIR="$HOME/Documents/Recordings"
LATEST_EEG="$(find "$RECORDING_DIR" -name "eeg.csv" -newermt "-5 minutes" 2>/dev/null | sort | tail -1)"
if [[ -z "$LATEST_EEG" ]]; then
    skip "Recorder writing at expected byte rate" "no recording started in the last 5 minutes"
else
    SIZE1=$(stat -f%z "$LATEST_EEG" 2>/dev/null || echo 0)
    sleep 1.5
    SIZE2=$(stat -f%z "$LATEST_EEG" 2>/dev/null || echo 0)
    if [[ "$SIZE2" -gt "$SIZE1" ]]; then
        pass "Recorder writing ($LATEST_EEG grew ${SIZE1} -> ${SIZE2} bytes over ~1.5s)"
    else
        fail "Recorder writing at expected byte rate" "$LATEST_EEG did not grow over ~1.5s"
    fi
fi

# ---------------------------------------------------------------------------
echo
echo "=== Interpretation ==="
echo "  (no external hook into classifier/SceneKit state exists yet — these"
echo "   need a human watching the app, or a future in-process debug dump"
echo "   built on NeuralWorkspaceView's existing testableEmissionIntensity()"
echo "   family of test-support accessors.)"
manual "Classifier produces non-uniform predictions after 30s of stable signal"
manual "3D workspace: node brightness/elevation respond to signal within 1s"
manual "Edge tint/pulse reflects classifier state"

# ---------------------------------------------------------------------------
echo
echo "=== Lifecycle ==="
manual "Clean shutdown releases the UDP port — verify with: $0 --after-quit --port $PORT"
manual "Reconnect after source interruption (tracked separately — see the deferred heartbeat-watchdog integration test)"
manual "Privacy indicator updates correctly after a source change (Live -> Playback -> Live)"

# ---------------------------------------------------------------------------
echo
echo "=== Summary ==="
echo "Automated: $PASS_COUNT passed, $FAIL_COUNT failed, ${#SKIP_ITEMS[@]} skipped"
echo "Still needs a human (${#MANUAL_ITEMS[@]}):"
for item in "${MANUAL_ITEMS[@]}"; do echo "  - $item"; done
if [[ ${#SKIP_ITEMS[@]} -gt 0 ]]; then
    echo "Skipped (${#SKIP_ITEMS[@]}):"
    for item in "${SKIP_ITEMS[@]}"; do echo "  - $item"; done
fi

exit $((FAIL_COUNT > 0 ? 1 : 0))
