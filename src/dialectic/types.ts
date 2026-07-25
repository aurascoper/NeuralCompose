// types.ts — value types for the dialectical engine.
// Ported from Swift DialecticalCompetition.swift + Embedding.swift.
// Pure TypeScript, no React/HTTP/storage/timers/randomness.

/** L2-normalized semantic vector with provenance metadata. */
export interface Embedding {
  /** Unit-length vector. Invariant: norm = 1. */
  values: number[];
  modelID: string;
  dimension: number;
  version: string;
  seed: number;
}

/** Three semantic axes, each in [0, 1]. */
export interface DialecticalEnergy {
  coherence: number;   // fidelity to heard
  resonance: number;   // fit to history centroid
  novelty: number;      // distance from reply centroid
}

/** Weights for the three axes, producing a single potential scalar. */
export interface DialecticalWeights {
  coherence: number;
  resonance: number;
  novelty: number;
}

/** A generated continuation with its embedding and role provenance. */
export interface DialecticalCandidate {
  text: string;
  embedding: Embedding;
  roleID: string;
}

/** Candidate + its score and role fulfillment. */
export interface ScoredCandidate {
  candidate: DialecticalCandidate;
  energy: DialecticalEnergy;
  potential: number;
  roleFulfillment: number;
}

/** What a turn resolves to. */
export type DialecticalOutcome =
  | { kind: 'spoke'; candidate: DialecticalCandidate }
  | { kind: 'silent' }
  | { kind: 'synthesized'; candidate: DialecticalCandidate };

/** Prosody shaping for a spoken utterance. */
export interface SpeechProsody {
  rate?: number;
  pitch?: number;
  volume?: number;
  preDelayMs?: number;
}

/** Spectral state for the gloss — absent is neutral. */
export type SpectralState =
  | 'drowsyFatigued'
  | 'relaxedWakefulness'
  | 'engagedFocused'
  | 'highCognitiveLoad'
  | 'neutralBaseline';

/** EEG wind absent/unavailable. */
export type SpectralStateOrAbsent = SpectralState | 'absent';

/** Kind of graph node. */
export type NodeKind = 'heard' | 'reply';

/** A node in the semantic graph. */
export interface SemanticNode {
  id: number;
  text: string;
  embedding: Embedding;
  turnIndex: number;
  kind: NodeKind;
}

/** An edge between two nodes. */
export interface SemanticEdge {
  a: number;
  b: number;
  weight: number;
}

/** Profile identifier. */
export type ProfileID = 'focused' | 'reflective' | 'contemplative';

/** Full tuning parameters for the dialectical engine. */
export interface DialecticTuning {
  tauBase: number;
  tauTensionSlope: number;
  tauMin: number;
  stalemateMargin: number;
  highTension: number;
  decisiveGap: number;
  weights: DialecticalWeights;
  synthesisHighBar: number;
  synthesisLowBar: number;
  synthesisSustainK: number;
  synthesisTensionCeiling: number;
  fieldInertia: number;
  glossEMAAlpha: number;
  glossWind: number;
  maxConsecutiveSilence: number;
  interTurnCooldownMs: number;
}

/** The result of a dialectical competition resolution. */
export interface CompetitionResult {
  outcome: DialecticalOutcome;
  tension: number;
  margin: number;
  selectionTemperature: number;
  decisive: boolean;
}

/** Service health status. */
export type ServiceStatus = 'ok' | 'degraded' | 'down' | 'unknown';

/** Health probe result for one service. */
export interface ServiceHealth {
  name: string;
  status: ServiceStatus;
  detail?: string;
  latencyMs?: number;
}

/** Turn timing record. */
export interface TurnTiming {
  recordingMs?: number;
  audioFinalizeMs?: number;
  sttMs?: number;
  coherenceGenerateMs?: number;
  displacementGenerateMs?: number;
  embeddingMs?: number;
  gateMs?: number;
  ttsStartMs?: number;
  ttsDurationMs?: number;
  processingToSpeechMs?: number;
  turnTotalMs: number;
  promptTokens?: number;
  completionTokens?: number;
  coldOrWarm?: 'cold' | 'warm';
  outcome: string;
  timeoutErrorCategory?: string;
}

/** Model manifest entry. */
export interface ModelManifest {
  baseModel: string;
  baseGgufPath: string;
  baseGgufSha256: string;
  finetuneStatus: 'baseline' | 'adapter' | 'merged' | 'unverified';
  adapterPath?: string;
  adapterSha256?: string;
  mergedGgufPath?: string;
  mergedGgufSha256?: string;
  quantization: string;
  contextLength: number;
  chatTemplate: string;
  trainingDataSha256?: string;
  trainingRunId?: string;
  llamaCppBuild: string;
  createdAt: string;
}