// profiles.ts — profile presets as data, not branches that duplicate the engine.
// Ported from Swift ContextProfile.swift.

import type { DialecticTuning, ProfileID, DialecticalWeights } from './types';

export const BALANCED_WEIGHTS: DialecticalWeights = {
  coherence: 1.0,
  resonance: 0.6,
  novelty: 0.8,
};

export const DEFAULT_TUNING: DialecticTuning = {
  tauBase: 0.5,
  tauTensionSlope: 0.35,
  tauMin: 0.12,
  stalemateMargin: 0.05,
  highTension: 0.6,
  decisiveGap: 0.25,
  weights: BALANCED_WEIGHTS,
  synthesisHighBar: 0.6,
  synthesisLowBar: 0.45,
  synthesisSustainK: 4,
  synthesisTensionCeiling: 0.35,
  fieldInertia: 0.12,
  glossEMAAlpha: 0.6,
  glossWind: 0.35,
  maxConsecutiveSilence: 3,
  interTurnCooldownMs: 3000,
};

export const PROFILES: Record<ProfileID, {
  label: string;
  summary: string;
  tuning: DialecticTuning;
  witnessEnabled: boolean;
}> = {
  focused: {
    label: 'Focused',
    summary: 'Coherent, grounded, conversational — resists drift, resolves readily, rarely silent.',
    tuning: {
      ...DEFAULT_TUNING,
      highTension: 0.75,
      weights: { coherence: 1.2, resonance: 0.8, novelty: 0.4 },
      synthesisHighBar: 0.5,
      synthesisLowBar: 0.4,
      synthesisSustainK: 3,
      glossWind: 0.2,
      maxConsecutiveSilence: 2,
      interTurnCooldownMs: 2000,
    },
    witnessEnabled: false,
  },
  reflective: {
    label: 'Reflective',
    summary: 'Gentle semantic exploration with tension that persists across turns (the default).',
    tuning: { ...DEFAULT_TUNING },
    // No Witness backend exists on Android; a true flag here would be a
    // decorative role label with no runtime behind it (the exact defect Apple
    // PR #32 found in the harness). Flip only when a Witness role resolves
    // through its own prompt path and identity.
    witnessEnabled: false,
  },
  contemplative: {
    label: 'Contemplative',
    summary: 'Slower and quieter — low novelty pressure, synthesis suppressed, high tolerance for silence.',
    tuning: {
      ...DEFAULT_TUNING,
      stalemateMargin: 0.12,
      highTension: 0.45,
      weights: { coherence: 0.9, resonance: 0.6, novelty: 0.5 },
      synthesisHighBar: 0.8,
      synthesisLowBar: 0.65,
      synthesisSustainK: 6,
      glossWind: 0.2,
      maxConsecutiveSilence: 6,
      interTurnCooldownMs: 6000,
    },
    witnessEnabled: false,
  },
};

export const PROFILE_IDS: ProfileID[] = ['focused', 'reflective', 'contemplative'];

export function getProfile(id: ProfileID) {
  return PROFILES[id];
}