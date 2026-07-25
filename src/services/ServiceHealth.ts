// ServiceHealth.ts — health probes for all local services.

import type { ServiceHealth } from '../dialectic/types';
import { generationAlive } from './GenerationClient';
import { embeddingAlive } from './EmbeddingClient';
import { sttAlive } from './TranscriptionClient';

export async function checkAllServices(): Promise<ServiceHealth[]> {
  const results = await Promise.all([
    checkGeneration(),
    checkEmbedding(),
    checkSTT(),
  ]);
  return results;
}

export async function checkGeneration(): Promise<ServiceHealth> {
  const start = Date.now();
  const alive = await generationAlive();
  return {
    name: 'Qwen',
    status: alive ? 'ok' : 'down',
    detail: alive ? 'llama-server responding' : 'llama-server not responding',
    latencyMs: Date.now() - start,
  };
}

export async function checkEmbedding(): Promise<ServiceHealth> {
  const start = Date.now();
  const alive = await embeddingAlive();
  return {
    name: 'Embeddings',
    status: alive ? 'ok' : 'down',
    detail: alive ? 'embedding server responding' : 'no embedding model (Gates: MOCK)',
    latencyMs: Date.now() - start,
  };
}

export async function checkSTT(): Promise<ServiceHealth> {
  const start = Date.now();
  const alive = await sttAlive();
  return {
    name: 'STT',
    status: alive ? 'ok' : 'down',
    detail: alive ? 'whisper service responding' : 'no STT service (text injection only)',
    latencyMs: Date.now() - start,
  };
}

export function checkTTS(): ServiceHealth {
  // expo-speech is always available on Android — no health check needed
  return {
    name: 'TTS',
    status: 'ok',
    detail: 'expo-speech (Android system TTS)',
  };
}