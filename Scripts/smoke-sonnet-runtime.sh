#!/usr/bin/env bash
# Phase-1 co-dev-loop smoke: prove Sonnet 5 is reachable and healthy as the
# app's runtime agent, through the real ClaudeCLIGenerator + waking role prompts,
# with no headband, EEG, or GUI. See Sources/DialecticSmoke/main.swift.
#
#   ./Scripts/smoke-sonnet-runtime.sh ["what was heard"]
#
# Requires the `claude` CLI installed and signed in (subscription auth, no API
# key). Exit 0 = both waking voices returned text; non-zero = runtime unhealthy.
set -euo pipefail

cd "$(dirname "$0")/.."

if ! command -v claude >/dev/null 2>&1; then
    echo "error: 'claude' CLI not on PATH — install it and sign in first." >&2
    exit 2
fi

exec swift run dialectic-smoke "${1:-I keep starting projects and never finishing them.}"
