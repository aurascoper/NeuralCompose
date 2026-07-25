// EmbeddingClient.ts — local sentence-embedding client for the dialectic gates.
// Talks to a llama-server embedding instance on a separate localhost port (8082).
// Falls back to a deterministic mock embedder when no embedding model is available.
// L2-normalizes defensively in TypeScript even when the service claims normalized output.

import type { Embedding } from '../dialectic/types';

export const EMBEDDING_URL = 'http://127.0.0.1:8082';
export const EMBEDDING_MODEL_PATH = '/data/data/com.termux/files/home/models/bge-small-en-v1.5-q8_0.gguf';

export interface EmbeddingResult {
  embeddings: Embedding[];
  modelID: string;
  latencyMs: number;
}

export interface EmbeddingError {
  reason: string;
  latencyMs: number;
}

export interface EmbeddingClientOptions {
  timeoutMs?: number;
  signal?: AbortSignal;
}

/** Batch-encode texts. Returns embeddings in the same order as input. */
export async function embedBatch(
  texts: string[],
  opts: EmbeddingClientOptions = {},
): Promise<EmbeddingResult | EmbeddingError> {
  const timeoutMs = opts.timeoutMs ?? 20000;
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);

  if (opts.signal) {
    if (opts.signal.aborted) {
      clearTimeout(timer);
      return { reason: 'cancelled', latencyMs: 0 };
    }
    opts.signal.addEventListener('abort', () => controller.abort(), { once: true });
  }

  const start = Date.now();

  try {
    const res = await fetch(`${EMBEDDING_URL}/v1/embeddings`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        input: texts,
        model: EMBEDDING_MODEL_PATH,
      }),
      signal: controller.signal,
    });
    clearTimeout(timer);

    if (!res.ok) {
      return { reason: `HTTP ${res.status}`, latencyMs: Date.now() - start };
    }
    const json = (await res.json()) as {
      data?: Array<{ embedding?: number[] }>;
      model?: string;
    };

    if (!json.data || json.data.length !== texts.length) {
      return { reason: 'embedding count mismatch', latencyMs: Date.now() - start };
    }

    const modelID = json.model ?? 'unknown';
    const embeddings: Embedding[] = json.data.map((d) => {
      const raw = d.embedding ?? [];
      // L2-normalize defensively
      const norm = Math.sqrt(raw.reduce((a, b) => a + b * b, 0));
      const values = norm > 0 ? raw.map((v) => v / norm) : raw;
      return {
        values,
        modelID,
        dimension: values.length,
        version: '1',
        seed: 0,
      };
    });

    const invalid = validateEmbeddingBatch(embeddings);
    if (invalid) {
      return { reason: invalid, latencyMs: Date.now() - start };
    }

    return { embeddings, modelID, latencyMs: Date.now() - start };
  } catch (err: any) {
    clearTimeout(timer);
    if (err?.name === 'AbortError') {
      return { reason: 'timeout', latencyMs: Date.now() - start };
    }
    return { reason: String(err?.message ?? err), latencyMs: Date.now() - start };
  }
}

/** Quick health check for the embedding server. */
export async function embeddingAlive(): Promise<boolean> {
  try {
    const ctrl = new AbortController();
    const t = setTimeout(() => ctrl.abort(), 2000);
    const res = await fetch(`${EMBEDDING_URL}/v1/models`, { signal: ctrl.signal });
    clearTimeout(t);
    return res.ok;
  } catch {
    return false;
  }
}

/**
 * Rejects vectors that are empty, non-finite, or dimensionally inconsistent
 * across the batch. Returns a reason string, or null when the batch is valid.
 */
export function validateEmbeddingBatch(embeddings: Embedding[]): string | null {
  if (embeddings.length === 0) return 'empty batch';
  const dim = embeddings[0].values.length;
  if (dim === 0) return 'zero-dimensional vector';
  for (const e of embeddings) {
    if (e.values.length !== dim) return 'dimension mismatch across batch';
    if (!e.values.every((v) => Number.isFinite(v))) return 'non-finite vector';
  }
  return null;
}

// MARK: - Deterministic Mock Embedder (test/mock provider only)

/**
 * Deterministic hash-based embedder for testing.
 * NOT a real semantic embedder. Shows `Gates: MOCK` when active.
 * Produces fixed-dimensional vectors from text hash so tests are reproducible.
 */
export function mockEmbed(texts: string[], dim = 64): Embedding[] {
  return texts.map((text) => {
    const values = new Array(dim).fill(0);
    // Simple deterministic hash: distribute characters into vector positions
    for (let i = 0; i < text.length; i++) {
      const pos = (text.charCodeAt(i) * 31 + i * 7) % dim;
      values[pos] += Math.sin(text.charCodeAt(i) * 0.1);
    }
    // Add a secondary hash for more spread
    for (let i = 0; i < text.length; i++) {
      const pos = (text.charCodeAt(i) * 17 + i * 13) % dim;
      values[pos] += Math.cos(text.charCodeAt(i) * 0.07);
    }
    // L2-normalize
    const norm = Math.sqrt(values.reduce((a, b) => a + b * b, 0));
    const normalized = norm > 0 ? values.map((v) => v / norm) : values;
    return {
      values: normalized,
      modelID: 'mock-hash-v1',
      dimension: dim,
      version: '1',
      seed: 0,
    };
  });
}