#!/usr/bin/env bash
# healthcheck-neuralcompose-services.sh — check all local services.

set -euo pipefail

HOME_DIR="${HOME:-/data/data/com.termux/files/home}"
LLM_PORT="${NEURALCOMPOSE_LLM_PORT:-8081}"
EMB_PORT="${NEURALCOMPOSE_EMB_PORT:-8082}"
STT_PORT="${NEURALCOMPOSE_STT_PORT:-8083}"

echo "=== NeuralCompose Service Health ==="
echo ""

# LLM (Qwen)
echo -n "Qwen (127.0.0.1:${LLM_PORT}): "
if curl -s --max-time 2 "http://127.0.0.1:${LLM_PORT}/health" >/dev/null 2>&1; then
  echo "OK"
else
  echo "DOWN"
fi

# Embeddings
echo -n "Embeddings (127.0.0.1:${EMB_PORT}): "
if curl -s --max-time 2 "http://127.0.0.1:${EMB_PORT}/health" >/dev/null 2>&1; then
  echo "OK"
else
  echo "DOWN (Gates: MOCK)"
fi

# STT
echo -n "STT (127.0.0.1:${STT_PORT}): "
if curl -s --max-time 2 "http://127.0.0.1:${STT_PORT}/health" >/dev/null 2>&1; then
  echo "OK"
else
  echo "DOWN (text injection only)"
fi

# TTS
echo "TTS (expo-speech): OK (Android system TTS)"

echo ""
echo "=== Model Provenance ==="
echo "LLM Model: Qwen2.5-0.5B-Instruct Q4_K_M"
echo "LLM Status: BASELINE (no fine-tune artifact)"
echo "LLM Path: ${HOME_DIR}/models/qwen2.5-0.5b-instruct-q4_k_m.gguf"
sha256sum "${HOME_DIR}/models/qwen2.5-0.5b-instruct-q4_k_m.gguf" 2>/dev/null | awk '{print "LLM SHA256: " $1}' || echo "LLM SHA256: (file not found)"

echo ""
echo "Embedding Model: bge-small-en-v1.5 Q8_0"
echo "Embedding Path: ${HOME_DIR}/models/bge-small-en-v1.5-q8_0.gguf"
sha256sum "${HOME_DIR}/models/bge-small-en-v1.5-q8_0.gguf" 2>/dev/null | awk '{print "Embedding SHA256: " $1}' || echo "Embedding SHA256: (file not found)"

echo ""
echo "STT Model: whisper-tiny.en-q5_1"
echo "STT Path: ${HOME_DIR}/models/ggml-tiny.en-q5_1.bin"
sha256sum "${HOME_DIR}/models/ggml-tiny.en-q5_1.bin" 2>/dev/null | awk '{print "STT SHA256: " $1}' || echo "STT SHA256: (file not found)"