#!/usr/bin/env bash
set -euo pipefail

# ──────────────────────────────────────────────────────────────
# status-neuralcompose-services.sh — show managed service state
# on the Pixel 8a.
# ──────────────────────────────────────────────────────────────

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
RUNTIME_DIR="$REPO_ROOT/.runtime/neuralcompose"
CONFIG_FILE="$RUNTIME_DIR/neuralcompose-services.env"

if [[ -f "$CONFIG_FILE" ]]; then
  # shellcheck source=/dev/null
  source "$CONFIG_FILE"
fi

QWEN_PORT="${QWEN_PORT:-8081}"
EMBED_PORT="${EMBED_PORT:-8083}"
STT_PORT="${STT_PORT:-8084}"
METRO_PORT="${METRO_PORT:-8082}"

_service_status() {
  local name="$1" match="$2" port="$3"
  local pid_file="$RUNTIME_DIR/pids/$name.pid"
  local log_file="$RUNTIME_DIR/logs/$name.log"
  local err_file="$RUNTIME_DIR/logs/$name.err"
  local configured="yes"
  local status="stopped"
  local rss=""
  local listening=""

  # Check if configured
  case "$name" in
    qwen)
      if [[ ! -f "${QWEN_BIN:-}" ]]; then configured="no (no binary)"; fi
      if [[ ! -f "${QWEN_MODEL:-}" ]]; then configured="no (no model)"; fi
      ;;
    embed)
      if [[ -z "${EMBED_BIN:-}" ]]; then configured="no (not configured)"; fi
      ;;
    stt)
      if [[ -z "${STT_BIN:-}" ]]; then configured="no (not configured)"; fi
      ;;
    metro)
      if ! command -v npx &>/dev/null; then configured="no (no npx)"; fi
      ;;
  esac

  # Check PID
  if [[ -f "$pid_file" ]]; then
    local pid
    pid="$(cat "$pid_file" 2>/dev/null)" || { status="stale PID"; }
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      local cmd
      cmd="$(ps -p "$pid" -o comm= 2>/dev/null)" || cmd=""
      if [[ "$cmd" == *"$match"* ]]; then
        status="running (PID $pid)"
        rss="$(ps -p "$pid" -o rss= 2>/dev/null | awk '{printf "%.0f MB", $1/1024}')" || rss=""
      else
        status="WRONG PROCESS: $cmd"
      fi
    else
      status="stale PID"
    fi
  fi

  # Check port
  if nc -z 127.0.0.1 "$port" 2>/dev/null; then
    listening="port $port open"
  fi

  # Check readiness for running services
  local ready=""
  if [[ "$status" == "running"* ]]; then
    case "$name" in
      qwen)
        local resp
        resp="$(curl -s http://127.0.0.1:"$port"/v1/models 2>/dev/null || true)"
        if echo "$resp" | grep -qi "qwen" 2>/dev/null; then
          ready="model confirmed"
        else
          ready="port open, model unconfirmed"
        fi
        ;;
      metro)
        if nc -z 127.0.0.1 "$port" 2>/dev/null; then
          ready="port open"
        fi
        ;;
    esac
  fi

  # Log size
  local log_size=""
  if [[ -f "$log_file" ]]; then
    log_size="$(du -h "$log_file" 2>/dev/null | cut -f1)"
  fi

  printf "  %-8s  %-30s  %-12s  %-20s  %s\n" "$name" "$status" "$rss" "$listening" "$ready"
  if [[ -n "$log_size" ]]; then
    printf "  %-8s  log: %s\n" "" "$log_file ($log_size)"
  fi
}

echo "NeuralCompose services — status"
echo ""
printf "  %-8s  %-30s  %-12s  %-20s  %s\n" "Service" "Status" "RSS" "Network" "Readiness"
printf "  %-8s  %-30s  %-12s  %-20s  %s\n" "--------" "------" "---" "-------" "--------"

_service_status "qwen" "llama-server" "$QWEN_PORT"
_service_status "embed" "llama-server" "$EMBED_PORT"
_service_status "stt" "whisper" "$STT_PORT"
_service_status "metro" "node" "$METRO_PORT"

# Total RSS
echo ""
total_rss=0
for pid_file in "$RUNTIME_DIR/pids"/*.pid; do
  [[ -f "$pid_file" ]] || continue
  pid="$(cat "$pid_file" 2>/dev/null)" || continue
  if kill -0 "$pid" 2>/dev/null; then
    rss_kb="$(ps -p "$pid" -o rss= 2>/dev/null)" || continue
    total_rss=$((total_rss + rss_kb))
  fi
done
echo "  Total managed RSS: $(awk "BEGIN {printf \"%.0f MB\", $total_rss/1024}")"
