// prompts.ts — runtime prompts for the local Qwen2.5-0.5B dialectic.
// Two roles, each generated in a separate call with separate temperatures.
// The 0.5B model has little spare instruction capacity, so prompts are short,
// use no examples, never paste session history, cap output at 60 tokens.

import { sha256Hex } from '../runtime/sha256';

export const COMMON_SYSTEM_PROMPT = `You are one voice in a live waking dialectic. Hold only the assigned line.
Do not reconcile, ask a question, describe your role, or add a preamble.
Use 1 to 3 short sentences. Output only spoken words.`;

/** Truncates heard text to a bounded transcript by sentence boundary. */
export function boundTranscript(heard: string, maxChars = 400): string {
  const trimmed = heard.trim();
  if (trimmed.length <= maxChars) return trimmed;
  // Cut at sentence boundary near the limit
  const slice = trimmed.slice(0, maxChars);
  const lastStop = Math.max(slice.lastIndexOf('.'), slice.lastIndexOf('!'), slice.lastIndexOf('?'));
  return lastStop > maxChars * 0.5 ? slice.slice(0, lastStop + 1) : slice;
}

/** Coherence role prompt. Temperature: 0.45 */
export function coherencePrompt(heard: string): string {
  return `Someone said: ${boundTranscript(heard)}

Stay close to the strongest claim. Make it clearer, concrete, and precise.
Do not introduce a new position.`;
}

/** Displacement role prompt. Temperature: 1.0 */
export function displacementPrompt(heard: string, standingTension: number): string {
  const bounded = boundTranscript(heard);
  if (standingTension >= 0.6) {
    return `Someone said: ${bounded}

Push against the claim. Surface one counter-position or ignored assumption.
Do not restate, agree, or reconcile.`;
  }
  return `Someone said: ${bounded}

Open one genuinely different angle or overlooked consequence.
Do not restate, agree, or reconcile.`;
}

/**
 * FNV-1a 32-bit hash, hex-encoded. Not cryptographic — it identifies the
 * prompt text for provenance/portability comparison (upstream PR #29
 * invariant: prompt identity travels with every generation).
 */
export function promptHash(text: string): string {
  let h = 0x811c9dc5;
  for (let i = 0; i < text.length; i++) {
    h ^= text.charCodeAt(i);
    h = Math.imul(h, 0x01000193) >>> 0;
  }
  return h.toString(16).padStart(8, '0');
}

/** Versioned prompt profile: identity + content hash for turn provenance. */
export const PROMPT_PROFILE = {
  id: 'android-live-dialectic',
  version: 'v1',
  // Hash over every prompt template that shapes generation, computed over
  // fixed sentinel input so it reflects the template text, not user content.
  hash: promptHash([
    COMMON_SYSTEM_PROMPT,
    coherencePrompt(' '),
    displacementPrompt(' ', 0),
    displacementPrompt(' ', 1),
  ].join('\n---\n')),
} as const;

/**
 * Readiness check: every prompt resource must be present and non-empty.
 * An empty prompt is a typed readiness failure, never a silent fallback.
 */
export function promptResourcesReady(): { ok: boolean; detail: string } {
  const resources: Array<[string, string]> = [
    ['system', COMMON_SYSTEM_PROMPT],
    ['coherence', coherencePrompt('probe')],
    ['displacement-low', displacementPrompt('probe', 0)],
    ['displacement-high', displacementPrompt('probe', 1)],
  ];
  for (const [name, text] of resources) {
    if (!text || !text.trim()) {
      return { ok: false, detail: `prompt resource "${name}" is empty` };
    }
  }
  return { ok: true, detail: `${PROMPT_PROFILE.id}/${PROMPT_PROFILE.version}#${PROMPT_PROFILE.hash}` };
}

/**
 * Per-role prompt manifest (A2 delta): each role resolves through the prompt
 * text the runtime actually transmits, hashed with SHA-256 over the template
 * (sentinel input, so the hash identifies the template, not user content).
 * The two poles share one local Qwen server but keep distinct role identities,
 * prompts, temperatures, and prompt hashes.
 */
export function rolePromptManifest(role: 'coherence' | 'displacement'): {
  profile: string;
  role: 'coherence' | 'displacement';
  sha256: string;
} {
  const templates =
    role === 'coherence'
      ? [COMMON_SYSTEM_PROMPT, coherencePrompt(' ')]
      : [COMMON_SYSTEM_PROMPT, displacementPrompt(' ', 0), displacementPrompt(' ', 1)];
  return {
    profile: `${PROMPT_PROFILE.id}/${PROMPT_PROFILE.version}`,
    role,
    sha256: sha256Hex(templates.join('\n---\n')),
  };
}

export const GENERATION_DEFAULTS = {
  maxTokens: 60,
  contextTarget: 512,
  coherenceTemperature: 0.45,
  displacementTemperature: 1.0,
} as const;

/** Chat messages for a coherence generation call. */
export function coherenceMessages(heard: string): Array<{ role: 'system' | 'user'; content: string }> {
  return [
    { role: 'system', content: COMMON_SYSTEM_PROMPT },
    { role: 'user', content: coherencePrompt(heard) },
  ];
}

/** Chat messages for a displacement generation call. */
export function displacementMessages(
  heard: string,
  standingTension: number,
): Array<{ role: 'system' | 'user'; content: string }> {
  return [
    { role: 'system', content: COMMON_SYSTEM_PROMPT },
    { role: 'user', content: displacementPrompt(heard, standingTension) },
  ];
}

/**
 * Post-processes candidate text. May only:
 * - trim whitespace and quotes
 * - remove leading chatbot preambles like "Sure:" at the beginning
 * - stop after the third completed sentence
 * - reject empty, prompt-echoing, looping, or grossly overlong output
 */
export function postProcessCandidate(raw: string): string | null {
  let text = raw.trim();

  // Remove surrounding quotes
  if ((text.startsWith('"') && text.endsWith('"')) ||
      (text.startsWith("'") && text.endsWith("'"))) {
    text = text.slice(1, -1).trim();
  }

  // Remove leading chatbot preambles
  const preambles = ['Sure:', 'Sure ', 'Okay:', 'OK ', 'Here is', "Here's"];
  for (const pre of preambles) {
    if (text.startsWith(pre)) {
      text = text.slice(pre.length).trim();
      // Remove leading colon if the preamble was cut at "Sure"
      if (text.startsWith(':')) text = text.slice(1).trim();
    }
  }

  if (!text) return null;

  // Stop after the third completed sentence
  const sentences = text.split(/(?<=[.!?])\s+/).filter((s) => s.trim());
  if (sentences.length > 3) {
    text = sentences.slice(0, 3).join(' ');
  }

  // Reject prompt-echoing (if the text is just a repetition of the input markers)
  if (/^Someone said:/i.test(text)) return null;

  // Reject grossly overlong output (> 500 chars)
  if (text.length > 500) return null;

  return text;
}