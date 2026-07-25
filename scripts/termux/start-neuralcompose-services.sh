#!/usr/bin/env bash
# start-neuralcompose-services.sh — start local services for the dialectic MVP.
# Starts: (1) Qwen chat-completions llama-server on :8081
#         (2) BGE embedding llama-server on :8082
#         (3) whisper.cpp server on :8083 (if built and model present)
# Uses absolute paths, writes PID/log files under a gitignored runtime directory.
# Rejects duplicate starts. Waits for health endpoints. Prints model hashes/ids.

set -euo pipefail

HOME_DIR="${HOME:-/data/data/com.termux/files/home}"
LLAMA_BIN="${HOME_DIR}/llama.cpp/build/bin/llama-server"
RUNTIME_DIR="${HOME_DIR}/.neuralcompose-runtime"

# Models
QWEN_MODEL="${HOME_DIR}/models/qwen2.5-0.5b-instruct-q4_k_m.gguf"
BGE_MODEL="${HOME_DIR}/models/bge-small-en-v1.5-q8_0.gguf"

# Ports
LLM_PORT="${NEURALCOMPOSE_LLM_PORT:-8081}"
EMB_PORT="${NEURALCOMPOSE_EMB_PORT:-8082}"
STT_PORT="${NEURALCOMPOSE_STT_PORT:-8083}"

# Build config
CONTEXT="${NEURALCOMPOSE_CONTEXT:-512}"
THREADS="${NEURALCOMPOSE_THREADS:-2}"

# Whisper (optional)
WHISPER_BIN="${HOME_DIR}/whisper.cpp/build/bin/whisper-server"
WHISPER_MODEL="${HOME_DIR}/models/ggml-tiny.en-q5_1.bin"

mkdir -p "${RUNTIME_DIR}"

# --- LLM server (Qwen) ---
LLM_PID_FILE="${RUNTIME_DIR}/llama-server.pid"
LLM_LOG_FILE="${RUNTIME_DIR}/llama-server.log"

start_llm() {
  if [ -f "${LLM_PID_FILE}" ] && kill -0 "$(cat "${LLM_PID_FILE}")" 2>/dev/null; then
    echo "Qwen server already running (PID $(cat "${LLM_PID_FILE}"))"
    return 0
  fi

  if [ ! -f "${QWEN_MODEL}" ]; then
    echo "ERROR: Qwen model not found at ${QWEN_MODEL}"
    exit 1
  fi

  echo "=== Starting Qwen (chat-completions) ==="
  echo "Model: ${QWEN_MODEL}"
  sha256sum "${QWEN_MODEL}" | awk '{print "SHA256: " $1}'
  echo "Port: 127.0.0.1:${LLM_PORT}"

  "${LLAMA_BIN}" \
    --model "${QWEN_MODEL}" \
    --host 127.0.0.1 \
    --port "${LLM_PORT}" \
    --ctx-size "${CONTEXT}" \
    --threads "${THREADS}" \
    > "${LLM_LOG_FILE}" 2>&1 &

  echo $! > "${LLM_PID_FILE}"
  echo "PID: $(cat "${LLM_PID_FILE}")"

  echo "Waiting for health..."
  for i in $(seq 1 30); do
    if curl -s --max-time 1 "http://127.0.0.1:${LLM_PORT}/health" >/dev/null 2>&1; then
      echo "Qwen: OK"
      return 0
    fi
    sleep 1
  done
  echo "ERROR: Qwen server did not become healthy"
  return 1
}

# --- Embedding server (BGE) ---
EMB_PID_FILE="${RUNTIME_DIR}/embedding-server.pid"
EMB_LOG_FILE="${RUNTIME_DIR}/embedding-server.log"

start_emb() {
  if [ -f "${EMB_PID_FILE}" ] && kill -0 "$(cat "${EMB_PID_FILE}")" 2>/dev/null; then
    echo "Embedding server already running (PID $(cat "${EMB_PID_FILE}"))"
    return 0
  fi

  if [ ! -f "${BGE_MODEL}" ]; then
    echo "WARNING: BGE model not found at ${BGE_MODEL}"
    echo "Gates will use MOCK embedder."
    return 0
  fi

  echo ""
  echo "=== Starting BGE (embeddings) ==="
  echo "Model: ${BGE_MODEL}"
  sha256sum "${BGE_MODEL}" | awk '{print "SHA256: " $1}'
  echo "Port: 127.0.0.1:${EMB_PORT}"

  "${LLAMA_BIN}" \
    --model "${BGE_MODEL}" \
    --host 127.0.0.1 \
    --port "${EMB_PORT}" \
    --embedding \
    --pooling mean \
    --ctx-size 512 \
    --threads "${THREADS}" \
    > "${EMB_LOG_FILE}" 2>&1 &

  echo $! > "${EMB_PID_FILE}"
  echo "PID: $(cat "${EMB_PID_FILE}")"

  echo "Waiting for health..."
  for i in $(seq 1 30); do
    if curl -s --max-time 1 "http://127.0.0.1:${EMB_PORT}/health" >/dev/null 2>&1; then
      echo "BGE: OK"
      return 0
    fi
    sleep 1
  done
  echo "WARNING: BGE server did not become healthy. Gates will use MOCK."
  return 0
}

# --- STT server (whisper.cpp, optional) ---
STT_PID_FILE="${RUNTIME_DIR}/whisper-server.pid"
STT_LOG_FILE="${RUNTIME_DIR}/whisper-server.log"

start_stt() {
  if [ -f "${STT_PID_FILE}" ] && kill -0 "$(cat "${STT_PID_FILE}")" 2>/dev/null; then
    echo "Whisper server already running (PID $(cat "${STT_PID_FILE}"))"
    return 0
  fi

  if [ ! -x "${WHISPER_BIN}" ]; then
    echo ""
    echo "=== STT: whisper.cpp not built ==="
    echo "STT will be unavailable (text injection only)."
    echo "To enable: clone and build whisper.cpp."
    return 0
  fi

  if [ ! -f "${WHISPER_MODEL}" ]; then
    echo ""
    echo "=== STT: whisper model not found ==="
    echo "Expected: ${WHISPER_MODEL}"
    echo "STT will be unavailable (text injection only)."
    return 0
  fi

  echo ""
  echo "=== Starting Whisper (STT) ==="
  echo "Model: ${WHISPER_MODEL}"
  echo "Port: 127.0.0.1:${STT_PORT}"

  "${WHISPER_BIN}" \
    --model "${WHISPER_MODEL}" \
    --host 127.0.0.1 \
    --port "${STT_PORT}" \
    > "${STT_LOG_FILE}" 2>&1 &

  echo $! > "${STT_PID_FILE}"
  echo "PID: $(cat "${STT_PID_FILE}")"

  echo "Waiting for health..."
  for i in $(seq 1 30); do
    if curl -s --max-time 1 "http://127.0.0.1:${STT_PORT}/health" >/dev/null 2>&1; then
      echo "Whisper: OK"
      return 0
    fi
    sleep 1
  done
  echo "WARNING: Whisper server did not become healthy. STT unavailable."
  return 0
}

# --- Main ---
start_llm
start_emb
start_stt

echo ""
echo "=== All services started ==="
echo "Qwen:        127.0.0.1:${LLM_PORT}"
echo "Embeddings:  127.0.0.1:${EMB_PORT}"
echo "STT:         127.0.0.1:${STT_PORT} (if available)"
echo ""
echo "Use stop-neuralcompose-services.sh to stop all."