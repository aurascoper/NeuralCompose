// prosody.ts — prosody shaping and probability-weighted blending.
// Ported from Swift SpeechSynthesizing.swift SpeechProsody + blend.
// Expo Speech uses 1.0 as normal rate (AVSpeech uses ~0.5), so Android presets
// are calibrated separately from the Swift values.

import type { SpeechProsody } from './types';

/** Waking coherence: present, natural-paced. */
export const WAKING_COHERENT: SpeechProsody = {
  rate: 1.00,
  pitch: 1.00,
  volume: 0.90,
  preDelayMs: 100,
};

/** Waking displacement: a touch quicker and brighter, audibly distinct. */
export const WAKING_DIVERGENT: SpeechProsody = {
  rate: 1.08,
  pitch: 1.06,
  volume: 0.90,
  preDelayMs: 50,
};

/** Hypnagogic stabilizer (experimental). */
export const HYPNAGOGIC_STABILIZER: SpeechProsody = {
  rate: 0.70,
  pitch: 0.80,
  volume: 0.60,
  preDelayMs: 400,
};

/** Hypnagogic dreamer (experimental). */
export const HYPNAGOGIC_DREAMER: SpeechProsody = {
  rate: 0.84,
  pitch: 0.98,
  volume: 0.60,
  preDelayMs: 300,
};

/** Base profile prosody for synthesis candidates. */
export const BASE_PROFILE: SpeechProsody = WAKING_COHERENT;

/**
 * Weighted mean of several prosodies — makes tension audible.
 * A spoken turn blends the role voices in proportion to competition probabilities.
 * nil/undefined fields abstain; non-positive weights are ignored.
 */
export function blendProsody(weighted: Array<{ prosody: SpeechProsody; weight: number }>): SpeechProsody {
  function mean(get: (p: SpeechProsody) => number | undefined): number | undefined {
    let acc = 0;
    let wsum = 0;
    for (const { prosody, weight } of weighted) {
      if (weight <= 0) continue;
      const v = get(prosody);
      if (v !== undefined) {
        acc += v * weight;
        wsum += weight;
      }
    }
    return wsum > 0 ? acc / wsum : undefined;
  }

  return {
    rate: mean((p) => p.rate),
    pitch: mean((p) => p.pitch),
    volume: mean((p) => p.volume),
    preDelayMs: mean((p) => p.preDelayMs),
  };
}

/** Gets prosody for a role by ID. Falls back to base profile for unknown roles (e.g. synthesis). */
export function prosodyForRole(roleID: string): SpeechProsody {
  switch (roleID) {
    case 'coherence-seeking': return WAKING_COHERENT;
    case 'displacement-seeking': return WAKING_DIVERGENT;
    default: return BASE_PROFILE;
  }
}