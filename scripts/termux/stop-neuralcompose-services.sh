#!/usr/bin/env bash
# stop-neuralcompose-services.sh — cleanly stop all local services.
# Only stops processes we own (by PID file).

set -euo pipefail

HOME_DIR="${HOME:-/data/data/com.termux/files/home}"
RUNTIME_DIR="${HOME_DIR}/.neuralcompose-runtime"

stop_by_pidfile() {
  local name="$1"
  local pidfile="$RUNTIME_DIR/$2"
  local logfile="$RUNTIME_DIR/$3"

  if [ ! -f "${pidfile}" ]; then
    return 0
  fi

  local PID
  PID=$(cat "${pidfile}")
  if kill -0 "${PID}" 2>/dev/null; then
    echo "Stopping ${name} (PID ${PID})..."
    kill "${PID}" 2>/dev/null || true
    for i in $(seq 1 10); do
      if ! kill -0 "${PID}" 2>/dev/null; then break; fi
      sleep 0.5
    done
    if kill -0 "${PID}" 2>/dev/null; then
      echo "Force killing ${name}..."
      kill -9 "${PID}" 2>/dev/null || true
    fi
    echo "${name} stopped."
  else
    echo "${name}: process ${PID} not running (stale PID file)."
  fi
  rm -f "${pidfile}"
}

stop_by_pidfile "Qwen" "llama-server.pid" "llama-server.log"
stop_by_pidfile "BGE" "embedding-server.pid" "embedding-server.log"
stop_by_pidfile "Whisper" "whisper-server.pid" "whisper-server.log"

echo "All services stopped."