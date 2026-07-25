#!/usr/bin/env bash
set -euo pipefail

# ──────────────────────────────────────────────────────────────
# stop-neuralcompose-services.sh — safely stop managed services
# on the Pixel 8a.
#
# Usage:
#   ./scripts/termux/stop-neuralcompose-services.sh [--runtime|--all]
#
#   --runtime   stop Qwen + embeddings + STT (default)
#   --all       stop everything including Metro
# ──────────────────────────────────────────────────────────────

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
RUNTIME_DIR="$REPO_ROOT/.runtime/neuralcompose"
MODE="${1:---runtime}"

_stop_service() {
  local name="$1" match="$2"
  local pid_file="$RUNTIME_DIR/pids/$name.pid"
  local log_file="$RUNTIME_DIR/logs/$name.log"

  if [[ ! -f "$pid_file" ]]; then
    echo "  [$name] not running (no PID file)"
    return 0
  fi

  local pid
  pid="$(cat "$pid_file" 2>/dev/null)" || { echo "  [$name] stale PID file"; rm -f "$pid_file"; return 0; }

  # Verify PID belongs to expected process
  local cmd
  cmd="$(ps -p "$pid" -o comm= 2>/dev/null)" || { echo "  [$name] PID $pid not found (stale)"; rm -f "$pid_file"; return 0; }
  if [[ "$cmd" != *"$match"* ]]; then
    echo "  [$name] PID $pid is $cmd, not $match — leaving untouched"
    return 0
  fi

  echo "  [$name] sending TERM to PID $pid"
  kill -TERM "$pid" 2>/dev/null || true

  # Wait with bounded timeout
  local waited=0
  while kill -0 "$pid" 2>/dev/null; do
    sleep 1
    waited=$((waited + 1))
    if [[ "$waited" -ge 10 ]]; then
      echo "  [$name] timeout — sending KILL to PID $pid"
      kill -KILL "$pid" 2>/dev/null || true
      break
    fi
  done

  rm -f "$pid_file"
  echo "  [$name] stopped"
}

echo "NeuralCompose services — stopping ($MODE)"

_stop_service "qwen" "llama-server"
_stop_service "embed" "llama-server"  # same binary, different port
_stop_service "stt" "whisper"

if [[ "$MODE" == "--all" ]]; then
  _stop_service "metro" "node"
fi

echo "Done."
