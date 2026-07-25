// modelManifest.ts — runtime model provenance manifest.
// Establishes what is actually installed on the Pixel.
// The public source repository does not contain model weights.

import type { ModelManifest } from '../dialectic/types';
import { LLM_URL } from '../config';

/**
 * The verified baseline manifest for the Pixel 8a.
 * No adapter or merged weights exist — this is BASELINE.
 */
export const BASELINE_MANIFEST: ModelManifest = {
  baseModel: 'Qwen2.5-0.5B-Instruct',
  baseGgufPath: '/data/data/com.termux/files/home/models/qwen2.5-0.5b-instruct-q4_k_m.gguf',
  baseGgufSha256: '74a4da8c9fdbcd15bd1f6d01d621410d31c6fc00986f5eb687824e7b93d7a9db',
  finetuneStatus: 'baseline',
  quantization: 'Q4_K_M',
  contextLength: 512,
  chatTemplate: 'qwen2.5-instruct',
  llamaCppBuild: 'llama.cpp 1 (0a50d99), Clang 21.1.8, Android aarch64',
  createdAt: '2026-07-25T00:00:00Z',
};

/**
 * Returns the active model manifest. In the baseline case this is static.
 * When an adapter is integrated, this would query the server for active model info.
 */
export function getManifest(): ModelManifest {
  return BASELINE_MANIFEST;
}

/** Returns the model path as the llama-server /v1/models expects it. */
export function getModelPath(): string {
  return BASELINE_MANIFEST.baseGgufPath;
}

/** Provenance badge text for UI. */
export function provenanceBadge(manifest: ModelManifest): string {
  switch (manifest.finetuneStatus) {
    case 'baseline': return 'BASELINE';
    case 'adapter': return 'ADAPTER';
    case 'merged': return 'MERGED';
    case 'unverified': return 'UNVERIFIED';
  }
}

/** Whether a fine-tuned artifact is verified. */
export function hasFineTunedArtifact(manifest: ModelManifest): boolean {
  return manifest.finetuneStatus === 'adapter' || manifest.finetuneStatus === 'merged';
}