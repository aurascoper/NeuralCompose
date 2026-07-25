// prosody.test.ts — Milestone 4: prosody coupling.
// Ported from Swift DialecticalProsodyTests.swift.

import { blendProsody, WAKING_COHERENT, WAKING_DIVERGENT } from '../prosody';
import type { SpeechProsody } from '../types';

describe('Prosody blend', () => {
  test('blend at endpoints returns each voice', () => {
    const allStab = blendProsody([{ prosody: WAKING_COHERENT, weight: 1 }, { prosody: WAKING_DIVERGENT, weight: 0 }]);
    const allDream = blendProsody([{ prosody: WAKING_COHERENT, weight: 0 }, { prosody: WAKING_DIVERGENT, weight: 1 }]);
    expect(allStab.pitch).toBeCloseTo(WAKING_COHERENT.pitch!, 5);
    expect(allDream.pitch).toBeCloseTo(WAKING_DIVERGENT.pitch!, 5);
    expect(allDream.rate).toBeCloseTo(WAKING_DIVERGENT.rate!, 5);
  });

  test('blend interpolates proportionally', () => {
    const mid = blendProsody([{ prosody: WAKING_COHERENT, weight: 1 }, { prosody: WAKING_DIVERGENT, weight: 1 }]);
    expect(mid.rate).toBeCloseTo((1.00 + 1.08) / 2, 5);
    expect(mid.pitch).toBeCloseTo((1.00 + 1.06) / 2, 5);
  });

  test('nil fields abstain and zero weights are ignored', () => {
    const onlyRate: SpeechProsody = { rate: 0.5 };
    const onlyPitch: SpeechProsody = { pitch: 1.2 };
    const b = blendProsody([
      { prosody: onlyRate, weight: 1 },
      { prosody: onlyPitch, weight: 1 },
      { prosody: WAKING_DIVERGENT, weight: 0 },
    ]);
    expect(b.rate).toBeCloseTo(0.5, 5);
    expect(b.pitch).toBeCloseTo(1.2, 5);
    expect(b.volume).toBeUndefined();
  });

  test('probability-weighted prosody blend is the weighted mean', () => {
    // Simulate 70% coherence, 30% displacement
    const blended = blendProsody([
      { prosody: WAKING_COHERENT, weight: 0.7 },
      { prosody: WAKING_DIVERGENT, weight: 0.3 },
    ]);
    const expectedRate = 0.7 * 1.00 + 0.3 * 1.08;
    const expectedPitch = 0.7 * 1.00 + 0.3 * 1.06;
    expect(blended.rate).toBeCloseTo(expectedRate, 5);
    expect(blended.pitch).toBeCloseTo(expectedPitch, 5);
  });
});