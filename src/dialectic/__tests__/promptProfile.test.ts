// promptProfile.test.ts — prompt resources are versioned, hashed, and non-empty.
// Upstream PR #29 invariant: an absent/empty prompt is a readiness failure.

import {
  PROMPT_PROFILE, promptHash, promptResourcesReady,
  COMMON_SYSTEM_PROMPT, coherencePrompt, displacementPrompt,
} from '../prompts';

describe('Prompt profile provenance', () => {
  test('promptHash is stable and content-sensitive', () => {
    expect(promptHash('abc')).toBe(promptHash('abc'));
    expect(promptHash('abc')).not.toBe(promptHash('abd'));
    expect(promptHash('')).toMatch(/^[0-9a-f]{8}$/);
  });

  test('PROMPT_PROFILE carries a non-empty hash over the template set', () => {
    expect(PROMPT_PROFILE.id).toBe('android-live-dialectic');
    expect(PROMPT_PROFILE.version).toBe('v1');
    expect(PROMPT_PROFILE.hash).toMatch(/^[0-9a-f]{8}$/);
  });

  test('readiness passes with the shipped prompts', () => {
    const r = promptResourcesReady();
    expect(r.ok).toBe(true);
    expect(r.detail).toContain(PROMPT_PROFILE.hash);
  });

  test('every prompt resource is non-empty', () => {
    expect(COMMON_SYSTEM_PROMPT.trim().length).toBeGreaterThan(0);
    expect(coherencePrompt('x').trim().length).toBeGreaterThan(0);
    expect(displacementPrompt('x', 0.2).trim().length).toBeGreaterThan(0);
    expect(displacementPrompt('x', 0.9).trim().length).toBeGreaterThan(0);
  });

  test('displacement prompt sharpens under standing tension', () => {
    expect(displacementPrompt('x', 0.2)).not.toBe(displacementPrompt('x', 0.9));
  });
});
