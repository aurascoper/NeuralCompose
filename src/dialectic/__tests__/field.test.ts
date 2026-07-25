// field.test.ts — Milestone 5: the two clocks (fast gloss EMA + slow weight field).
// Ported from Swift DialecticalFieldTests.swift.

import { SpectralGloss } from '../spectralGloss';
import { DialecticalField } from '../field';
import { BALANCED_WEIGHTS } from '../profiles';

describe('SpectralGloss (fast clock)', () => {
  test('relaxed is high, engaged is low, neutral/absent is mid', () => {
    expect(SpectralGloss.scalar('drowsyFatigued')).toBeGreaterThan(0.9);
    expect(SpectralGloss.scalar('relaxedWakefulness')).toBeGreaterThan(0.6);
    expect(SpectralGloss.scalar('neutralBaseline')).toBeCloseTo(0.5, 5);
    expect(SpectralGloss.scalar('absent')).toBeCloseTo(0.5, 5);
    expect(SpectralGloss.scalar('engagedFocused')).toBeLessThan(0.4);
    expect(SpectralGloss.scalar('highCognitiveLoad')).toBeLessThan(0.3);
  });

  test('EMA moves toward but not all the way', () => {
    const g = new SpectralGloss(0.5);
    g.update('drowsyFatigued', 0.6); // target 1.0
    expect(g.value).toBeCloseTo(0.5 + 0.6 * 0.5, 5);
  });
});

describe('DialecticalField (slow clock)', () => {
  test('starts unbiased at base', () => {
    const f = new DialecticalField(BALANCED_WEIGHTS, 0.12, 0.35);
    expect(f.weights).toEqual(BALANCED_WEIGHTS);
  });

  test('sustained relaxation shifts toward novelty', () => {
    const f = new DialecticalField(BALANCED_WEIGHTS, 0.2, 0.35);
    const n0 = f.weights.novelty;
    for (let i = 0; i < 30; i++) {
      f.advance(1.0, 0, 0);
    }
    expect(f.weights.novelty).toBeGreaterThan(n0);
    expect(f.weights.coherence).toBeLessThan(BALANCED_WEIGHTS.coherence);
  });

  test('sustained engagement shifts toward coherence', () => {
    const f = new DialecticalField(BALANCED_WEIGHTS, 0.2, 0.35);
    for (let i = 0; i < 30; i++) {
      f.advance(0.0, 0, 0);
    }
    expect(f.weights.novelty).toBeLessThan(BALANCED_WEIGHTS.novelty);
    expect(f.weights.coherence).toBeGreaterThan(BALANCED_WEIGHTS.coherence);
  });

  test('high entropy reins in novelty', () => {
    const calm = new DialecticalField(BALANCED_WEIGHTS, 0.2, 0.35);
    const wandering = new DialecticalField(BALANCED_WEIGHTS, 0.2, 0.35);
    for (let i = 0; i < 30; i++) {
      calm.advance(1.0, 0.0, 0.0);
      wandering.advance(1.0, 0.9, 0.9);
    }
    expect(wandering.weights.novelty).toBeLessThan(calm.weights.novelty);
  });

  test('one window spike barely moves the weights (two-clock separation)', () => {
    const f = new DialecticalField(BALANCED_WEIGHTS, 0.12, 0.35);
    const before = f.weights.novelty;
    f.advance(1.0, 0, 0);
    const delta = Math.abs(f.weights.novelty - before);
    expect(delta).toBeLessThan(0.35 * 0.12 + 1e-4);
  });
});