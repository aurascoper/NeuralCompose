// GenerationClient.ts — local Qwen2.5-0.5B chat-completions client for dialectic roles.
// Makes two separate calls with separate temperatures, one per role.
// Uses the existing llama-server on 127.0.0.1:8081 via OpenAI-compatible API.
// Does NOT replace the existing LLMClient (which the Journal depends on).

import { LLM_URL } from '../config';
import { coherenceMessages, displacementMessages, postProcessCandidate,
  GENERATION_DEFAULTS } from '../dialectic/prompts';
import { classifyModelMatch } from '../runtime/identity';
import type { ModelManifest } from '../dialectic/types';

export interface GenerationResult {
  text: string;
  promptTokens: number;
  completionTokens: number;
  latencyMs: number;
}

export interface GenerationError {
  reason: string;
  latencyMs: number;
}

export interface GenerationClientOptions {
  timeoutMs?: number;
  modelPath?: string;
  signal?: AbortSignal;
}

/** Generates one candidate for a role. */
export async function generateCandidate(
  roleID: 'coherence-seeking' | 'displacement-seeking',
  heard: string,
  standingTension: number,
  manifest: ModelManifest | null,
  opts: GenerationClientOptions = {},
): Promise<GenerationResult | GenerationError> {
  const timeoutMs = opts.timeoutMs ?? 30000; // generous for 0.5B on Pixel
  const model = opts.modelPath ?? manifest?.baseGgufPath ?? '';
  const messages = roleID === 'coherence-seeking'
    ? coherenceMessages(heard)
    : displacementMessages(heard, standingTension);

  const temperature = roleID === 'coherence-seeking'
    ? GENERATION_DEFAULTS.coherenceTemperature
    : GENERATION_DEFAULTS.displacementTemperature;

  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);

  // Link external signal if provided
  if (opts.signal) {
    if (opts.signal.aborted) {
      clearTimeout(timer);
      return { reason: 'cancelled', latencyMs: 0 };
    }
    opts.signal.addEventListener('abort', () => controller.abort(), { once: true });
  }

  const start = Date.now();

  try {
    const res = await fetch(`${LLM_URL}/v1/chat/completions`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        model,
        messages,
        max_tokens: GENERATION_DEFAULTS.maxTokens,
        temperature,
        stream: false,
      }),
      signal: controller.signal,
    });
    clearTimeout(timer);

    if (!res.ok) {
      return { reason: `HTTP ${res.status}`, latencyMs: Date.now() - start };
    }
    const json = (await res.json()) as {
      choices?: Array<{ message?: { content?: string } }>;
      usage?: { prompt_tokens?: number; completion_tokens?: number };
    };
    const raw = json.choices?.[0]?.message?.content?.trim() ?? '';
    const processed = postProcessCandidate(raw);
    if (!processed) {
      return { reason: 'empty or rejected output', latencyMs: Date.now() - start };
    }
    return {
      text: processed,
      promptTokens: json.usage?.prompt_tokens ?? 0,
      completionTokens: json.usage?.completion_tokens ?? 0,
      latencyMs: Date.now() - start,
    };
  } catch (err: any) {
    clearTimeout(timer);
    if (err?.name === 'AbortError') {
      return { reason: 'timeout', latencyMs: Date.now() - start };
    }
    return { reason: String(err?.message ?? err), latencyMs: Date.now() - start };
  }
}

/** Quick health check for the generation server. */
export async function generationAlive(): Promise<boolean> {
  try {
    const ctrl = new AbortController();
    const t = setTimeout(() => ctrl.abort(), 2000);
    const res = await fetch(`${LLM_URL}/v1/models`, { signal: ctrl.signal });
    clearTimeout(t);
    return res.ok;
  } catch {
    return false;
  }
}

export interface GenerationProbe {
  /** True only on an EXACT configured-model match (A2 delta: alias is not READY). */
  ready: boolean;
  detail: string;
  /** Model ids the server positively reported (empty when unreachable/none). */
  reportedModelIds: string[];
  /** Null when the endpoint responded; a reason string when it did not. */
  probeError: string | null;
}

/**
 * Positive model probe (fail-closed readiness, upstream PR #31/R18 invariant):
 * the server must not only respond, it must report the configured model as
 * loaded. Liveness alone is not READY — a server with the wrong (or no) model
 * must be discovered before the first generation, not during it. An alias-only
 * overlap is UNVERIFIED, not ready (A2 delta / Apple PR #32 parity).
 */
export async function generationModelReady(
  expectedModelPath: string,
): Promise<GenerationProbe> {
  try {
    const ctrl = new AbortController();
    const t = setTimeout(() => ctrl.abort(), 3000);
    const res = await fetch(`${LLM_URL}/v1/models`, { signal: ctrl.signal });
    clearTimeout(t);
    if (!res.ok) {
      return { ready: false, detail: `HTTP ${res.status}`, reportedModelIds: [], probeError: `HTTP ${res.status}` };
    }
    // llama-server builds differ: OpenAI-style {data:[{id}]} vs {models:[{name|model}]}.
    const json = (await res.json()) as {
      data?: Array<{ id?: string }>;
      models?: Array<{ name?: string; model?: string }>;
    };
    const ids = [
      ...(json.data ?? []).map((m) => m.id ?? ''),
      ...(json.models ?? []).map((m) => m.name ?? m.model ?? ''),
    ].filter(Boolean);
    if (ids.length === 0) {
      return { ready: false, detail: 'no model loaded', reportedModelIds: [], probeError: null };
    }
    const match = classifyModelMatch(expectedModelPath, ids);
    const expectedBase = expectedModelPath.split('/').pop() ?? expectedModelPath;
    if (match === 'exact') {
      return { ready: true, detail: ids[0], reportedModelIds: ids, probeError: null };
    }
    const reason = match === 'alias'
      ? `served model "${ids[0]}" is only an alias of configured "${expectedBase}" — unverified`
      : `loaded model "${ids[0]}" does not match configured "${expectedBase}"`;
    return { ready: false, detail: reason, reportedModelIds: ids, probeError: null };
  } catch (err: any) {
    const reason = err?.name === 'AbortError' ? 'timeout' : String(err?.message ?? err);
    return { ready: false, detail: reason, reportedModelIds: [], probeError: reason };
  }
}