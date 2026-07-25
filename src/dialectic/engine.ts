// engine.ts — the dialectical engine: orchestrates one turn through the kernel.
// Ported from the Swift HypnagogicDialecticLoop.runTurn() logic.
// Pure orchestration over injected seams; no React/HTTP/timers/randomness.
// The engine is a plain object, not a class — state is passed in and returned.

import type {
  Embedding, DialecticalCandidate, ScoredCandidate, CompetitionResult,
  DialecticTuning, DialecticalWeights, DialecticalOutcome, SpeechProsody,
  SpectralStateOrAbsent,
} from './types';
import {
  energy, potential, tension, compete, probabilities, centroid,
  cosineSimilarity, normalizedCosine, synthesisScore,
} from './dynamics';
import { DialecticalMemory } from './memory';
import { DialecticalField } from './field';
import { SpectralGloss } from './spectralGloss';
import { blendProsody, prosodyForRole } from './prosody';

/** State carried across turns. */
export interface EngineState {
  standingTension: number;
  memory: DialecticalMemory;
  field: DialecticalField;
  gloss: SpectralGloss;
  turnIndex: number;
  consecutiveSilence: number;
}

/** Creates initial engine state from tuning. */
export function createEngineState(tuning: DialecticTuning): EngineState {
  return {
    standingTension: 0,
    memory: new DialecticalMemory(16, 128, 0.6, tuning.synthesisTensionCeiling),
    field: new DialecticalField(tuning.weights, tuning.fieldInertia, tuning.glossWind),
    gloss: new SpectralGloss(0.5),
    turnIndex: 0,
    consecutiveSilence: 0,
  };
}

/** Input for one turn. */
export interface TurnInput {
  heard: string;
  /** Candidate texts from generation (roleID -> text). */
  candidates: Array<{ roleID: string; text: string }>;
  /** Embeddings: heard + all candidates, batched in one request. */
  embeddings: Embedding[];
  /** Single uniform draw in [0, 1). */
  draw: number;
  /** Current spectral state (or absent). */
  spectralState: SpectralStateOrAbsent;
  /**
   * Whether semantic synthesis may fire this turn.
   * Must be false when gates run on a MOCK embedder: mock vectors cannot
   * establish that a prior reply genuinely bridges the poles.
   */
  allowSynthesis?: boolean;
}

/** Output of one turn. */
export interface TurnOutput {
  result: CompetitionResult;
  scored: ScoredCandidate[];
  weights: DialecticalWeights;
  glossScalar: number;
  synthesisCandidate: DialecticalCandidate | null;
  /** Prosody blended by competition probabilities. */
  prosody: SpeechProsody;
  /** Whether the turn spoke, was silent, or synthesized. */
  outcome: DialecticalOutcome;
  /** Text to speak (null if silent). */
  spokenText: string | null;
  /** Role ID of the spoken candidate (or 'synthesis' / null). */
  spokenRoleID: string | null;
}

/**
 * Runs one dialectical turn through the full pipeline:
 * 1. Score candidates against accumulated trajectory
 * 2. Advance clocks (fast gloss + slow field)
 * 3. Check for synthesis from memory
 * 4. Compete (synthesis -> silence -> sample)
 * 5. Record turn and act
 */
export function runTurn(
  state: EngineState,
  input: TurnInput,
  tuning: DialecticTuning,
): TurnOutput {
  const { heard, candidates, embeddings, draw, spectralState } = input;
  const allowSynthesis = input.allowSynthesis ?? true;

  // Embeddings: [heard, ...candidates]
  const heardEmb = embeddings[0];
  const candidateEmbs = embeddings.slice(1);

  // Advance clocks
  state.gloss.update(spectralState, tuning.glossEMAAlpha);
  const weights = state.field.advance(
    state.gloss.value,
    state.memory.entropy,
    state.memory.drift,
  );

  // Score candidates
  const historyCentroid = state.memory.historyCentroid;
  const replyCentroid = state.memory.replyCentroid;

  const scored: ScoredCandidate[] = candidates.map((c, i) => {
    const emb = candidateEmbs[i];
    const e = energy(emb, heardEmb, historyCentroid, replyCentroid);
    return {
      candidate: { text: c.text, embedding: emb, roleID: c.roleID },
      energy: e,
      potential: potential(e, weights),
      roleFulfillment: c.roleID === 'coherence-seeking' ? e.coherence : e.novelty,
    };
  });

  const currentTension = tension(candidateEmbs);

  // Check for synthesis from memory
  let synthesis: DialecticalCandidate | null = null;
  if (allowSynthesis && candidateEmbs.length >= 2) {
    const [i, j] = mostOpposedPair(candidateEmbs);
    synthesis = state.memory.synthesisCandidate(
      candidateEmbs[i],
      candidateEmbs[j],
      tuning,
    );
  }

  // Compete
  const result = compete(
    scored,
    currentTension,
    draw,
    tuning,
    synthesis,
    synthesis !== null,
  );

  // Record turn
  state.memory.recordHeard(heard, heardEmb, state.turnIndex);
  state.memory.observe(currentTension);
  state.standingTension = currentTension;

  // Compute prosody blend from competition probabilities
  const probs = probabilities(
    scored.map((s) => s.potential),
    result.selectionTemperature,
  );
  const prosody = blendProsody(
    scored.map((s, i) => ({ prosody: prosodyForRole(s.candidate.roleID), weight: probs[i] })),
  );

  // Determine spoken text
  let spokenText: string | null = null;
  let spokenRoleID: string | null = null;

  switch (result.outcome.kind) {
    case 'spoke': {
      const c = result.outcome.candidate;
      spokenText = c.text;
      spokenRoleID = c.roleID;
      state.consecutiveSilence = 0;
      state.memory.recordReply(c.text, c.embedding, state.turnIndex);
      state.memory.recordVoiced(c.text);
      break;
    }
    case 'synthesized': {
      const c = result.outcome.candidate;
      spokenText = c.text;
      spokenRoleID = c.roleID;
      state.consecutiveSilence = 0;
      state.memory.recordReply(c.text, c.embedding, state.turnIndex);
      state.memory.recordVoiced(c.text);
      break;
    }
    case 'silent': {
      state.consecutiveSilence++;
      break;
    }
  }

  state.turnIndex++;

  return {
    result,
    scored,
    weights,
    glossScalar: state.gloss.value,
    synthesisCandidate: synthesis,
    prosody,
    outcome: result.outcome,
    spokenText,
    spokenRoleID,
  };
}

/** Indices of the two most semantically opposed candidate embeddings. */
function mostOpposedPair(embeddings: Embedding[]): [number, number] {
  let best: [number, number] = [0, 1];
  let worst = -1;
  for (let i = 0; i < embeddings.length; i++) {
    for (let j = i + 1; j < embeddings.length; j++) {
      const d = 1 - normalizedCosine(cosineSimilarity(embeddings[i], embeddings[j]));
      if (d > worst) {
        worst = d;
        best = [i, j];
      }
    }
  }
  return best;
}