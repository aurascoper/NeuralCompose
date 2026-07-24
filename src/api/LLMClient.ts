// LLMClient — talks to the local llama-server (Qwen 0.5B Q4_K_M) on 127.0.0.1:8081.
// Used by the dream journal to rewrite user-typed reports in the chosen dialect.
//
// This is intentionally minimal: a single chat-completions call with a timeout.
// It does NOT cache, retry, or queue. The journal screen treats synthesis as
// fire-and-forget; the raw text is the durable record.
//
// Network surface: only the URL in src/config.ts (LLM_URL). On the same device
// as llama-server, 127.0.0.1 reaches the loopback. usesCleartextTraffic is
// enabled in app.json (expo-build-properties) so HTTP to localhost is allowed.

import { LLM_URL } from '../config';
import { buildDialectMessages } from '../prompts/dialect';

export type SynthesisStatus = 'pending' | 'ok' | 'failed';

export interface SynthesisResult {
  synthesized: string;
  status: 'ok';
  promptTokens: number;
  completionTokens: number;
}

export interface SynthesisError {
  status: 'failed';
  reason: string;
}

const DEFAULT_TIMEOUT_MS = 8000;
const MAX_INPUT_CHARS = 600; // keep well under the 1024-token context window

export async function synthesizeDream(
  rawText: string,
  opts: { timeoutMs?: number } = {},
): Promise<SynthesisResult | SynthesisError> {
  const trimmed = rawText.trim();
  if (!trimmed) {
    return { status: 'failed', reason: 'empty input' };
  }
  // Small models bloat and lose the voice on long inputs. Truncate hard.
  const input = trimmed.length > MAX_INPUT_CHARS ? trimmed.slice(0, MAX_INPUT_CHARS) : trimmed;

  const controller = new AbortController();
  const timeoutMs = opts.timeoutMs ?? DEFAULT_TIMEOUT_MS;
  const timer = setTimeout(() => controller.abort(), timeoutMs);

  try {
    const res = await fetch(`${LLM_URL}/v1/chat/completions`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        messages: buildDialectMessages(input),
        max_tokens: 140,
        temperature: 0.7,
        stream: false,
      }),
      signal: controller.signal,
    });
    clearTimeout(timer);

    if (!res.ok) {
      return { status: 'failed', reason: `HTTP ${res.status}` };
    }
    const json = (await res.json()) as {
      choices?: Array<{ message?: { content?: string } }>;
      usage?: { prompt_tokens?: number; completion_tokens?: number };
    };
    const content = json.choices?.[0]?.message?.content?.trim() ?? '';
    if (!content) {
      return { status: 'failed', reason: 'empty response' };
    }
    return {
      status: 'ok',
      synthesized: content,
      promptTokens: json.usage?.prompt_tokens ?? 0,
      completionTokens: json.usage?.completion_tokens ?? 0,
    };
  } catch (err: any) {
    clearTimeout(timer);
    if (err?.name === 'AbortError') {
      return { status: 'failed', reason: 'timeout' };
    }
    return { status: 'failed', reason: String(err?.message ?? err) };
  }
}
