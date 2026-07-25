#!/usr/bin/env bash
set -euo pipefail

# ──────────────────────────────────────────────────────────────
# healthcheck-neuralcompose-services.sh — verify managed services
# are responding correctly on the Pixel 8a.
# ──────────────────────────────────────────────────────────────

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
RUNTIME_DIR="$REPO_ROOT/.runtime/neuralcompose"
CONFIG_FILE="$RUNTIME_DIR/neuralcompose-services.env"

if [[ -f "$CONFIG_FILE" ]]; then
  # shellcheck source=/dev/null
  source "$CONFIG_FILE"
fi

QWEN_PORT="${QWEN_PORT:-8081}"
QWEN_MODEL="${QWEN_MODEL:-qwen}"
EMBED_PORT="${EMBED_PORT:-8083}"
STT_PORT="${STT_PORT:-8084}"
METRO_PORT="${METRO_PORT:-8082}"

failed=0

_check_qwen() {
  local resp
  resp="$(curl -s http://127.0.0.1:"$QWEN_PORT"/v1/models 2>/dev/null)" || {
    echo "  [qwen] FAIL: endpoint unreachable on port $QWEN_PORT"
    return 1
  }
  if echo "$resp" | grep -qi "$QWEN_MODEL" 2>/dev/null; then
    echo "  [qwen] OK: model $QWEN_MODEL identified"
  else
    echo "  [qwen] WARN: endpoint reachable but model not confirmed"
    echo "  [qwen] response: $(echo "$resp" | head -c 200)"
  fi
}

_check_embed() {
  if ! nc -z 127.0.0.1 "$EMBED_PORT" 2>/dev/null; then
    echo "  [embed] SKIP: not running on port $EMBED_PORT"
    return 0
  fi
  local resp
  resp="$(curl -s http://127.0.0.1:"$EMBED_PORT"/v1/embeddings \
    -H 'Content-Type: application/json' \
    -d '{"input":"probe","model":"default"}' 2>/dev/null)" || {
    echo "  [embed] FAIL: endpoint unreachable"
    return 1
  }
  local dim
  dim="$(echo "$resp" | python3 -c "import sys,json; d=json.load(sys.stdin); print(len(d['data'][0]['embedding']))" 2>/dev/null)" || {
    echo "  [embed] FAIL: response did not contain expected embedding shape"
    return 1
  }
  echo "  [embed] OK: dimension $dim"
}

_check_stt() {
  if ! nc -z 127.0.0.1 "$STT_PORT" 2>/dev/null; then
    echo "  [stt] SKIP: not running on port $STT_PORT"
    return 0
  fi
  local resp
  resp="$(curl -s http://127.0.0.1:"$STT_PORT"/health 2>/dev/null)" || {
    echo "  [stt] FAIL: endpoint unreachable"
    return 1
  }
  echo "  [stt] OK: health endpoint responded"
}

_check_metro() {
  if ! nc -z 127.0.0.1 "$METRO_PORT" 2>/dev/null; then
    echo "  [metro] SKIP: not running on port $METRO_PORT"
    return 0
  fi
  local resp
  resp="$(curl -s http://127.0.0.1:"$METRO_PORT"/ 2>/dev/null)" || {
    echo "  [metro] FAIL: endpoint unreachable"
    return 1
  }
  echo "  [metro] OK: port $METRO_PORT responding"
}

echo "NeuralCompose services — healthcheck"
echo ""

_check_qwen || failed=$((failed + 1))
_check_embed || failed=$((failed + 1))
_check_stt || failed=$((failed + 1))
_check_metro || failed=$((failed + 1))

echo ""
if [[ "$failed" -eq 0 ]]; then
  echo "All services healthy."
else
  echo "$failed service(s) unhealthy."
  exit 1
fi
