// dynamics.ts — the pure math of one dialectical turn.
// Ported from Swift DialecticalDynamics.swift.
// No I/O, no React, no HTTP, no timers, no randomness globals.
// Every function is a pure mapping, fully testable with fixed embeddings and draws.

import type {
  Embedding, DialecticalEnergy, DialecticalWeights, ScoredCandidate,
  DialecticalCandidate, DialecticalOutcome, CompetitionResult, DialecticTuning,
} from './types';

/** Maps a raw cosine [-1, 1] onto [0, 1]. */
export function normalizedCosine(cosine: number): number {
  return (cosine + 1) / 2;
}

/** Cosine similarity of two L2-normalized embeddings (dot product). */
export function cosineSimilarity(a: Embedding, b: Embedding): number {
  if (a.values.length !== b.values.length) return 0;
  let acc = 0;
  for (let i = 0; i < a.values.length; i++) {
    acc += a.values[i] * b.values[i];
  }
  return acc;
}

/**
 * Scores one candidate against the turn context.
 * Missing centroids (early turns) score neutral 0.5 rather than biasing.
 */
export function energy(
  candidate: Embedding,
  heard: Embedding,
  historyCentroid: Embedding | null,
  replyCentroid: Embedding | null,
): DialecticalEnergy {
  const coherence = normalizedCosine(cosineSimilarity(candidate, heard));
  const resonance = historyCentroid
    ? normalizedCosine(cosineSimilarity(candidate, historyCentroid))
    : 0.5;
  const novelty = replyCentroid
    ? 1 - normalizedCosine(cosineSimilarity(candidate, replyCentroid))
    : 0.5;
  return { coherence, resonance, novelty };
}

/** Weighted dialectical potential = <weights, energy>. */
export function potential(
  e: DialecticalEnergy,
  w: DialecticalWeights,
): number {
  return w.coherence * e.coherence + w.resonance * e.resonance + w.novelty * e.novelty;
}

/**
 * Mean pairwise dissimilarity among candidate embeddings, on [0, 1].
 * Zero or one candidate => no tension.
 */
export function tension(embeddings: Embedding[]): number {
  if (embeddings.length < 2) return 0;
  let acc = 0;
  let pairs = 0;
  for (let i = 0; i < embeddings.length; i++) {
    for (let j = i + 1; j < embeddings.length; j++) {
      acc += 1 - normalizedCosine(cosineSimilarity(embeddings[i], embeddings[j]));
      pairs++;
    }
  }
  return pairs === 0 ? 0 : acc / pairs;
}

/** tau(tension): higher tension -> lower temperature -> sharper competition. */
export function selectionTemperature(tension: number, tuning: DialecticTuning): number {
  return Math.max(tuning.tauMin, tuning.tauBase - tuning.tauTensionSlope * tension);
}

/** Numerically stable softmax over potentials / tau. */
export function probabilities(potentials: number[], tau: number): number[] {
  if (potentials.length === 0) return [];
  if (tau <= 0) {
    return new Array(potentials.length).fill(1 / potentials.length);
  }
  const maxP = Math.max(...potentials);
  const exps = potentials.map((p) => Math.exp((p - maxP) / tau));
  const sum = exps.reduce((a, b) => a + b, 0);
  if (sum <= 0) {
    return new Array(potentials.length).fill(1 / potentials.length);
  }
  return exps.map((e) => e / sum);
}

/**
 * Samples an index from probabilities using an injected uniform draw in [0, 1).
 * This is the single point of non-determinism, isolated for deterministic tests.
 */
export function sample(probabilities: number[], draw: number): number {
  if (probabilities.length === 0) return 0;
  let cumulative = 0;
  const d = Math.min(Math.max(draw, 0), 0.999999);
  for (let i = 0; i < probabilities.length; i++) {
    cumulative += probabilities[i];
    if (d < cumulative) return i;
  }
  return probabilities.length - 1;
}

/**
 * Synthesis score: how well a candidate reconciles two poles.
 * min(sim(c, thesis), sim(c, antithesis)) on [0, 1].
 */
export function synthesisScore(
  c: Embedding,
  thesis: Embedding,
  antithesis: Embedding,
): number {
  const toThesis = normalizedCosine(cosineSimilarity(c, thesis));
  const toAnti = normalizedCosine(cosineSimilarity(c, antithesis));
  return Math.min(toThesis, toAnti);
}

/**
 * Resolves a scored competition into an outcome.
 * Precedence: (1) forced synthesis, (2) high-tension stalemate silence, (3) sampled basin.
 */
export function compete(
  scored: ScoredCandidate[],
  tension: number,
  draw: number,
  tuning: DialecticTuning,
  synthesis?: DialecticalCandidate | null,
  forceSynthesis?: boolean,
): CompetitionResult {
  const tau = selectionTemperature(tension, tuning);
  const potentialsArr = scored.map((s) => s.potential);
  const sorted = [...potentialsArr].sort((a, b) => b - a);
  const margin = sorted.length >= 2 ? sorted[0] - sorted[1] : (sorted[0] ?? 0);
  const decisive = margin >= tuning.decisiveGap;

  // 1. Synthesis resolves the standing contradiction.
  if (synthesis && forceSynthesis) {
    return { outcome: { kind: 'synthesized', candidate: synthesis }, tension, margin, selectionTemperature: tau, decisive };
  }

  // Nothing to say.
  if (scored.length === 0) {
    return { outcome: { kind: 'silent' }, tension, margin, selectionTemperature: tau, decisive };
  }

  // 2. Metastable stalemate: opposed + undecided => hold tension, say nothing.
  if (scored.length >= 2 && margin < tuning.stalemateMargin && tension >= tuning.highTension) {
    return { outcome: { kind: 'silent' }, tension, margin, selectionTemperature: tau, decisive };
  }

  // 3. Symmetry-breaking: sample a basin.
  const probs = probabilities(potentialsArr, tau);
  const idx = sample(probs, draw);
  return { outcome: { kind: 'spoke', candidate: scored[idx].candidate }, tension, margin, selectionTemperature: tau, decisive };
}

/** L2-normalized mean of embeddings — "direction the dialogue has been traveling." */
export function centroid(embeddings: Embedding[]): Embedding | null {
  if (embeddings.length === 0) return null;
  const first = embeddings[0];
  const dim = first.values.length;
  const sum = new Array(dim).fill(0);
  for (const e of embeddings) {
    if (e.values.length !== dim) continue;
    for (let i = 0; i < dim; i++) {
      sum[i] += e.values[i];
    }
  }
  const norm = Math.sqrt(sum.reduce((a, b) => a + b * b, 0));
  const values = norm > 1e-6 ? sum.map((s) => s / norm) : sum;
  return {
    values,
    modelID: first.modelID,
    dimension: dim,
    version: first.version,
    seed: 0,
  };
}

/** L2-normalize a raw vector into an Embedding. */
export function makeEmbedding(
  v: number[],
  modelID: string,
  version: string = '1',
  seed: number = 0,
): Embedding {
  const norm = Math.sqrt(v.reduce((a, b) => a + b * b, 0));
  const values = norm > 0 ? v.map((x) => x / norm) : v;
  return { values, modelID, dimension: v.length, version, seed };
}