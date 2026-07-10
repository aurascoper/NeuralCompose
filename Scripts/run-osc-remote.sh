#!/usr/bin/env bash
#
# run-osc-remote.sh — launch NeuralCompose listening for a remote Muse over
# OSC (e.g. a phone running Mind Monitor, relayed over a private VPN).
#
# This is the one transport that touches the network at runtime. It must
# only be reached over a private VPN interface (Tailscale, WireGuard,
# ZeroTier) between the remote device and this Mac — OSC has no
# authentication or encryption of its own. Do not port-forward this to the
# public internet.
#
# Usage:
#   ./Scripts/run-osc-remote.sh                  # listen on the default port (5000)
#   ./Scripts/run-osc-remote.sh --port 6000       # listen on a different port
#
# Then in Mind Monitor's settings, set:
#   OSC Host = this Mac's Tailscale (or other VPN) IP
#   OSC Port = the port you passed here (5000 by default)
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

PORT="5000"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --port)
            PORT="$2"; shift 2 ;;
        -h|--help)
            grep '^#' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *)
            echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

export NEURALCOMPOSE_BOARD_PROFILE="osc"
export NEURALCOMPOSE_OSC_PORT="$PORT"

echo "Listening for Mind Monitor OSC on UDP port $PORT (all interfaces)."
echo "Reach this only via a private VPN (e.g. Tailscale) — never the public internet."
echo

exec swift run -c debug NeuralCompose
