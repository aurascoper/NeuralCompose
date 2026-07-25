// dynamics.test.ts — Milestone 1: the pure competition engine.
// Ported from Swift DialecticalDynamicsTests.swift.
// Every test is deterministic: fixed embeddings and fixed random draw, no I/O, no actors.

import { makeEmbedding, energy, tension, selectionTemperature,
  probabilities, sample, compete, synthesisScore, centroid } from '../dynamics';
import { DEFAULT_TUNING } from '../profiles';
import type { ScoredCandidate, Embedding } from '../types';

function emb(v: number[], id = 'test-v1'): Embedding {
  return makeEmbedding(v, id);
}

function scored(
  potential: number,
  roleID = 'r',
  text = 'x',
  energyVals: { coherence: number; resonance: number; novelty: number } = { coherence: 0.5, resonance: 0.5, novelty: 0.5 },
): ScoredCandidate {
  return {
    candidate: { text, embedding: emb([1, 0]), roleID },
    energy: energyVals,
    potential,
    roleFulfillment: 0.5,
  };
}

describe('DialecticalDynamics', () => {
  // MARK: - Energy

  test('identical candidate/heard gives coherence 1.0', () => {
    const heard = emb([1, 0, 0]);
    const e = energy(emb([1, 0, 0]), heard, null, null);
    expect(e.coherence).toBeCloseTo(1.0, 5);
  });

  test('missing centroids give resonance and novelty 0.5', () => {
    const e = energy(emb([0, 1, 0]), emb([1, 0, 0]), null, null);
    expect(e.resonance).toBeCloseTo(0.5, 5);
    expect(e.novelty).toBeCloseTo(0.5, 5);
  });

  test('novelty increases with distance from reply history', () => {
    const replies = emb([1, 0, 0]);
    const near = energy(emb([1, 0, 0]), emb([0, 1, 0]), null, replies);
    const far = energy(emb([-1, 0, 0]), emb([0, 1, 0]), null, replies);
    expect(far.novelty).toBeGreaterThan(near.novelty);
  });

  // MARK: - Tension

  test('identical candidates give tension 0', () => {
    expect(tension([emb([1, 0]), emb([1, 0])])).toBeCloseTo(0, 5);
  });

  test('opposed candidates give tension 1', () => {
    expect(tension([emb([1, 0]), emb([-1, 0])])).toBeCloseTo(1.0, 5);
  });

  // MARK: - Selection temperature

  test('higher tension lowers tau but never below tauMin', () => {
    const t = DEFAULT_TUNING;
    const cool = selectionTemperature(0, t);
    const hot = selectionTemperature(1, t);
    expect(cool).toBeGreaterThan(hot);
    expect(hot).toBeGreaterThanOrEqual(t.tauMin);
  });

  // MARK: - Sampling / bifurcation

  test('equal potentials: low draw selects first basin, high draw selects second', () => {
    const a = scored(0.50, 'a', 'A');
    const b = scored(0.50, 'b', 'B');
    const low = compete([a, b], 0.2, 0.01, DEFAULT_TUNING);
    const high = compete([a, b], 0.2, 0.99, DEFAULT_TUNING);
    expect(low.outcome.kind).toBe('spoke');
    if (low.outcome.kind === 'spoke') expect(low.outcome.candidate.text).toBe('A');
    expect(high.outcome.kind).toBe('spoke');
    if (high.outcome.kind === 'spoke') expect(high.outcome.candidate.text).toBe('B');
    expect(low.decisive).toBe(false);
  });

  test('decisive gap is stable against a mid-range draw', () => {
    const a = scored(1.30, 'a', 'A');
    const b = scored(0.20, 'b', 'B');
    const res = compete([a, b], 0.8, 0.5, DEFAULT_TUNING);
    expect(res.outcome.kind).toBe('spoke');
    if (res.outcome.kind === 'spoke') expect(res.outcome.candidate.text).toBe('A');
    expect(res.decisive).toBe(true);
  });

  // MARK: - Silence (metastability)

  test('high-tension tiny-margin competition becomes silent', () => {
    const a = scored(0.50, 'a');
    const b = scored(0.51, 'b');
    const res = compete([a, b], 0.8, 0.5, DEFAULT_TUNING);
    expect(res.outcome.kind).toBe('silent');
  });

  test('low-tension tiny-margin competition still speaks', () => {
    const a = scored(0.50, 'a', 'A');
    const b = scored(0.51, 'b', 'B');
    const res = compete([a, b], 0.1, 0.99, DEFAULT_TUNING);
    expect(res.outcome.kind).not.toBe('silent');
  });

  // MARK: - Synthesis

  test('forced synthesis takes precedence over would-be silence', () => {
    const a = scored(0.50, 'a');
    const b = scored(0.51, 'b');
    const third = { text: 'the reconciling image', embedding: emb([0, 0, 1]), roleID: 'synthesis' };
    const res = compete([a, b], 0.9, 0.5, DEFAULT_TUNING, third, true);
    expect(res.outcome.kind).toBe('synthesized');
    if (res.outcome.kind === 'synthesized') expect(res.outcome.candidate.text).toBe('the reconciling image');
  });

  test('bridge candidate out-scores a copy of one pole', () => {
    const thesis = emb([1, 0, 0]);
    const antithesis = emb([0, 1, 0]);
    const bridge = emb([0.4, 0.4, 0.9]);
    const copyOfThesis = emb([1, 0, 0]);
    const bridgeScore = synthesisScore(bridge, thesis, antithesis);
    const copyScore = synthesisScore(copyOfThesis, thesis, antithesis);
    expect(bridgeScore).toBeGreaterThan(copyScore);
    expect(copyScore).toBeCloseTo(0.5, 5);
  });
});