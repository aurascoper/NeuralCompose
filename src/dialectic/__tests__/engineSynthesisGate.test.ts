// engineSynthesisGate.test.ts — synthesis eligibility is governed by the
// engine, and allowSynthesis=false (MOCK gates) suppresses it entirely.

import { createEngineState, runTurn } from '../engine';
import { getProfile } from '../profiles';
import { makeEmbedding } from '../dynamics';

const tuning = { ...getProfile('focused').tuning, synthesisHighBar: 0.1, synthesisLowBar: 0.1 };

function turnInput(allowSynthesis: boolean | undefined) {
  const heard = makeEmbedding([1, 0, 0], 't');
  const coh = makeEmbedding([0.9, 0.1, 0], 't');
  const disp = makeEmbedding([-0.9, 0.1, 0], 't');
  return {
    heard: 'heard text',
    candidates: [
      { roleID: 'coherence-seeking', text: 'coh' },
      { roleID: 'displacement-seeking', text: 'disp' },
    ],
    embeddings: [heard, coh, disp],
    draw: 0.5,
    spectralState: 'absent' as const,
    allowSynthesis,
  };
}

function seededState() {
  const state = createEngineState(tuning);
  // A prior reply that bridges both poles and trivially clears the lowered bar.
  state.memory.recordReply('the bridge', makeEmbedding([0, 1, 0.2], 't'), 0);
  return state;
}

describe('Engine synthesis gate', () => {
  test('with allowSynthesis=true (default), the seeded bridge fires', () => {
    const out = runTurn(seededState(), turnInput(undefined), tuning);
    expect(out.synthesisCandidate).not.toBeNull();
    expect(out.outcome.kind).toBe('synthesized');
  });

  test('with allowSynthesis=false (MOCK gates), synthesis never fires', () => {
    const out = runTurn(seededState(), turnInput(false), tuning);
    expect(out.synthesisCandidate).toBeNull();
    expect(out.outcome.kind).not.toBe('synthesized');
  });
});
