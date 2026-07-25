// spectralGloss.ts — the fast biological clock: EMA-smoothed gloss from SpectralState.
// Ported from Swift SpectralGloss.swift.
// A bias signal, NOT a cognitive read. Only nudges the weight field; never selects a response.

import type { SpectralStateOrAbsent } from './types';

export class SpectralGloss {
  value: number;

  constructor(value = 0.5) {
    this.value = value;
  }

  /** Maps a SpectralState to the relaxation scalar [0, 1]. Absent reads as neutral. */
  static scalar(state: SpectralStateOrAbsent): number {
    switch (state) {
      case 'drowsyFatigued': return 1.0;
      case 'relaxedWakefulness': return 0.8;
      case 'neutralBaseline':
      case 'absent': return 0.5;
      case 'engagedFocused': return 0.2;
      case 'highCognitiveLoad': return 0.1;
    }
  }

  /** Advances the EMA one window toward the current state's scalar. */
  update(state: SpectralStateOrAbsent, alpha: number): void {
    const target = SpectralGloss.scalar(state);
    this.value += alpha * (target - this.value);
  }
}