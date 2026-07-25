#!/usr/bin/env bash
# shellcheck disable=SC2317
set -euo pipefail

# ──────────────────────────────────────────────────────────────
# start-neuralcompose-services.sh — bring up local runtime services
# on the Pixel 8a for device validation.
#
# Usage:
#   ./scripts/termux/start-neuralcompose-services.sh [--runtime|--dev|--all]
#
#   --runtime   Qwen generation + embeddings + STT (default)
#   --dev       Metro bundler only
#   --all       everything
# ──────────────────────────────────────────────────────────────

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
RUNTIME_DIR="$REPO_ROOT/.runtime/neuralcompose"
CONFIG_FILE="$REPO_ROOT/.runtime/neuralcompose/neuralcompose-services.env"
MODE="${1:---runtime}"

mkdir -p "$RUNTIME_DIR/pids" "$RUNTIME_DIR/logs" "$RUNTIME_DIR/state"

# Source local config if present
if [[ -f "$CONFIG_FILE" ]]; then
  # shellcheck source=/dev/null
  source "$CONFIG_FILE"
fi

# Defaults — override in neuralcompose-services.env
QWEN_PORT="${QWEN_PORT:-8081}"
QWEN_MODEL="${QWEN_MODEL:-$HOME/models/qwen2.5-0.5b-instruct-q4_k_m.gguf}"
QWEN_BIN="${QWEN_BIN:-$HOME/llama.cpp/build/bin/llama-server}"
QWEN_CONTEXT="${QWEN_CONTEXT:-1024}"
QWEN_THREADS="${QWEN_THREADS:-2}"

EMBED_PORT="${EMBED_PORT:-8083}"
EMBED_BIN="${EMBED_BIN:-}"
EMBED_MODEL="${EMBED_MODEL:-}"

STT_PORT="${STT_PORT:-8084}"
STT_BIN="${STT_BIN:-}"
STT_MODEL="${STT_MODEL:-}"

METRO_PORT="${METRO_PORT:-8082}"
METRO_DIR="${METRO_DIR:-$REPO_ROOT}"

# ── Helpers ──────────────────────────────────────────────────

_pid_file() { echo "$RUNTIME_DIR/pids/$1.pid"; }
_log_file() { echo "$RUNTIME_DIR/logs/$1.log"; }
_err_file() { echo "$RUNTIME_DIR/logs/$1.err"; }

_is_running() {
  local pid_file; pid_file="$(_pid_file "$1")"
  [[ -f "$pid_file" ]] || return 1
  local pid; pid="$(cat "$pid_file" 2>/dev/null)" || return 1
  [[ -n "$pid" ]] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  # Verify it's the expected process
  local cmd; cmd="$(ps -p "$pid" -o comm= 2>/dev/null)" || return 1
  [[ "$cmd" == *"$2"* ]] || return 1
  return 0
}

_start_service() {
  local name="$1" match="$2" pid_file; pid_file="$(_pid_file "$name")"
  if _is_running "$name" "$match"; then
    echo "  [$name] already running (PID $(cat "$pid_file"))"
    return 0
  fi
  shift 2
  echo "  [$name] starting..."
  nohup "$@" > "$(_log_file "$name")" 2> "$(_err_file "$name")" &
  local pid=$!
  echo "$pid" > "$pid_file"
  echo "  [$name] PID $pid"
}

_wait_for_port() {
  local port="$1" timeout="${2:-10}"
  for i in $(seq 1 "$timeout"); do
    if nc -z 127.0.0.1 "$port" 2>/dev/null; then
      return 0
    fi
    sleep 1
  done
  return 1
}

_wait_for_model_ready() {
  local port="$1" model_fragment="$2" timeout="${3:-30}"
  for i in $(seq 1 "$timeout"); do
    local resp
    resp="$(curl -s http://127.0.0.1:"$port"/v1/models 2>/dev/null || true)"
    if echo "$resp" | grep -qi "$model_fragment" 2>/dev/null; then
      return 0
    fi
    sleep 1
  done
  return 1
}

# ── Start functions ─────────────────────────────────────────

_start_qwen() {
  if [[ ! -f "$QWEN_BIN" ]]; then
    echo "  [qwen] SKIP: $QWEN_BIN not found"
    return 1
  fi
  if [[ ! -f "$QWEN_MODEL" ]]; then
    echo "  [qwen] SKIP: $QWEN_MODEL not found"
    return 1
  fi
  _start_service "qwen" "llama-server" \
    "$QWEN_BIN" \
    -m "$QWEN_MODEL" \
    --port "$QWEN_PORT" --host 127.0.0.1 \
    -c "$QWEN_CONTEXT" -t "$QWEN_THREADS"
  if _wait_for_port "$QWEN_PORT" 15; then
    if _wait_for_model_ready "$QWEN_PORT" "qwen" 30; then
      echo "  [qwen] ready on port $QWEN_PORT"
    else
      echo "  [qwen] WARNING: port open but model not confirmed"
    fi
  else
    echo "  [qwen] FAILED: port $QWEN_PORT not listening"
    return 1
  fi
}

_start_metro() {
  if ! command -v npx &>/dev/null; then
    echo "  [metro] SKIP: npx not found"
    return 1
  fi
  if [[ ! -f "$METRO_DIR/package.json" ]]; then
    echo "  [metro] SKIP: no package.json in $METRO_DIR"
    return 1
  fi
  _start_service "metro" "node" \
    npx expo start --port "$METRO_PORT" --no-dev --minify
  if _wait_for_port "$METRO_PORT" 30; then
    echo "  [metro] ready on port $METRO_PORT"
  else
    echo "  [metro] WARNING: port $METRO_PORT not confirmed"
  fi
}

# ── Main ─────────────────────────────────────────────────────

echo "NeuralCompose services — starting ($MODE)"

case "$MODE" in
  --runtime)
    _start_qwen
    # Embeddings and STT are not yet configured — add when binaries exist
    echo "  [embed] SKIP: no binary configured"
    echo "  [stt]   SKIP: no binary configured"
    ;;
  --dev)
    _start_metro
    ;;
  --all)
    _start_qwen
    _start_metro
    echo "  [embed] SKIP: no binary configured"
    echo "  [stt]   SKIP: no binary configured"
    ;;
  *)
    echo "Unknown mode: $MODE" >&2
    echo "Usage: $0 [--runtime|--dev|--all]" >&2
    exit 1
    ;;
esac

echo "Done."
