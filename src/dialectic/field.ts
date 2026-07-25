// field.ts — the slow semantic clock: competition weights as a vector field.
// Ported from Swift DialecticalField.swift.
// Eases weights a fraction (inertia) toward a target derived from gloss + entropy/drift.

import type { DialecticalWeights } from './types';

export class DialecticalField {
  weights: DialecticalWeights;
  readonly base: DialecticalWeights;
  readonly inertia: number;
  readonly wind: number;

  constructor(base: DialecticalWeights, inertia: number, wind: number) {
    this.base = base;
    this.weights = { ...base };
    this.inertia = Math.max(0, Math.min(1, inertia));
    this.wind = wind;
  }

  /** Eases the weights one turn toward the biased target. */
  advance(glossScalar: number, entropy: number, drift: number): DialecticalWeights {
    const target = DialecticalField.target(
      this.base, glossScalar, entropy, drift, this.wind,
    );
    this.weights = {
      coherence: this.lerp(this.weights.coherence, target.coherence),
      resonance: this.lerp(this.weights.resonance, target.resonance),
      novelty: this.lerp(this.weights.novelty, target.novelty),
    };
    return this.weights;
  }

  private lerp(a: number, b: number): number {
    return a + (b - a) * this.inertia;
  }

  /**
   * Where the weights want to be given the current bias.
   * - relaxed (glossScalar -> 1) favours novelty
   * - engaged (glossScalar -> 0) favours coherence/resonance
   * - wandering (high entropy) reins novelty back in
   * - fast drift damps novelty further
   */
  static target(
    base: DialecticalWeights,
    glossScalar: number,
    entropy: number,
    drift: number,
    wind: number,
  ): DialecticalWeights {
    const lean = (glossScalar - 0.5) * 2; // [-1, 1]: + relaxed, - engaged
    let novelty = base.novelty + wind * lean;
    const coherence = base.coherence - 0.5 * wind * lean;
    const resonance = base.resonance - 0.5 * wind * lean;
    novelty -= 0.5 * wind * entropy;
    novelty -= 0.5 * wind * drift;
    return {
      coherence: Math.max(0, coherence),
      resonance: Math.max(0, resonance),
      novelty: Math.max(0, novelty),
    };
  }
}