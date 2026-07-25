// turnPipeline.ts — one live dialectical turn, from transcript to settled speech.
// This is THE execution path: the UI hook, integration tests, and any benchmark
// harness must all run turns through here (upstream invariant: no split paths).
//
// All I/O is injected, so the pipeline is fully testable with fake services.
// Event dispatch order is exactly the legal reducer sequence starting from
// the 'transcribing' state. The pipeline never dispatches an event the
// reducer would reject.
//
// Failure policy (fail closed, no hidden fallback):
// - a role generation failure ends the turn as a degraded error, not a decision;
// - an embedding failure ends the turn: no semantic selection is made and
//   nothing is spoken — the pipeline NEVER swaps in the mock embedder mid-turn;
// - under MOCK gates, semantic synthesis is disabled;
// - a TTS error settles (SPEAKING_FAILED) before the caller may re-arm the mic.

import type { SessionEvent } from '../dialectic/sessionReducer';
import type { DialecticTuning, Embedding, SpeechProsody, TurnTiming } from '../dialectic/types';
import { runTurn, type EngineState, type TurnOutput } from '../dialectic/engine';
import { validateEmbeddingBatch } from '../services/EmbeddingClient';

export interface GenerationOutcome {
  text?: string;
  promptTokens?: number;
  completionTokens?: number;
  latencyMs: number;
  reason?: string;
}

export interface EmbeddingOutcome {
  embeddings?: Embedding[];
  modelID?: string;
  latencyMs: number;
  reason?: string;
}

export interface SpeechOutcome {
  cancelled: boolean;
  error?: boolean;
  durationMs: number;
}

/** Everything the pipeline needs, injected. No direct HTTP/native imports. */
export interface TurnDeps {
  generate: (
    roleID: 'coherence-seeking' | 'displacement-seeking',
    heard: string,
    standingTension: number,
  ) => Promise<GenerationOutcome>;
  embedLive: (texts: string[]) => Promise<EmbeddingOutcome>;
  embedMock: (texts: string[]) => Embedding[];
  speak: (text: string, prosody: SpeechProsody) => Promise<SpeechOutcome>;
  dispatch: (event: SessionEvent) => void;
  /** False when the session epoch has moved on; stale work must stop silently. */
  isCurrent: () => boolean;
  rng: () => number;
  nowMs: () => number;
}

export interface TurnRequest {
  transcript: string;
  embeddingMode: 'live' | 'mock';
  tuning: DialecticTuning;
  engineState: EngineState;
  /** Short static local cue spoken when the consecutive-silence cap is hit. */
  silenceCueText: string;
}

export interface TurnReport {
  status: 'complete' | 'stale' | 'error';
  errorReason?: string;
  turnOutput?: TurnOutput;
  draw?: number;
  timing: TurnTiming;
  cueSpoken: boolean;
}

export async function runLiveTurn(deps: TurnDeps, req: TurnRequest): Promise<TurnReport> {
  const { transcript, embeddingMode, tuning, engineState } = req;
  const timing: TurnTiming = { turnTotalMs: 0, outcome: 'pending' };
  const turnStart = deps.nowMs();

  const fail = (reason: string): TurnReport => {
    deps.dispatch({ type: 'ERROR', reason });
    timing.outcome = 'error';
    timing.timeoutErrorCategory = reason;
    timing.turnTotalMs = deps.nowMs() - turnStart;
    return { status: 'error', errorReason: reason, timing, cueSpoken: false };
  };
  const stale = (): TurnReport => {
    timing.outcome = 'stale';
    timing.turnTotalMs = deps.nowMs() - turnStart;
    return { status: 'stale', timing, cueSpoken: false };
  };

  // transcribing -> generatingCoherence
  deps.dispatch({ type: 'TRANSCRIBED', transcript });

  const coh = await deps.generate('coherence-seeking', transcript, engineState.standingTension);
  if (!deps.isCurrent()) return stale();
  if (coh.reason || !coh.text) return fail(`Coherence generation failed: ${coh.reason ?? 'empty'}`);
  timing.coherenceGenerateMs = coh.latencyMs;
  deps.dispatch({ type: 'COHERENCE_GENERATED', text: coh.text });

  const disp = await deps.generate('displacement-seeking', transcript, engineState.standingTension);
  if (!deps.isCurrent()) return stale();
  if (disp.reason || !disp.text) return fail(`Displacement generation failed: ${disp.reason ?? 'empty'}`);
  timing.displacementGenerateMs = disp.latencyMs;
  deps.dispatch({ type: 'DISPLACEMENT_GENERATED', text: disp.text });

  // Embed [heard, coherence, displacement] — state is 'embedding' here.
  const texts = [transcript, coh.text, disp.text];
  let embeddings: Embedding[];
  const embedStart = deps.nowMs();
  if (embeddingMode === 'live') {
    const emb = await deps.embedLive(texts);
    if (!deps.isCurrent()) return stale();
    if (emb.reason || !emb.embeddings) {
      // Fail closed: a live session must not quietly decide on mock vectors.
      return fail(`Embedding failed: ${emb.reason ?? 'no vectors'} — turn abandoned, nothing spoken`);
    }
    embeddings = emb.embeddings;
  } else {
    embeddings = deps.embedMock(texts);
  }
  const invalid = validateEmbeddingBatch(embeddings);
  if (invalid) return fail(`Embedding invalid: ${invalid}`);
  timing.embeddingMs = deps.nowMs() - embedStart;
  deps.dispatch({ type: 'EMBEDDED' });

  // Gate — state is 'gating'.
  const draw = deps.rng();
  const gateStart = deps.nowMs();
  const turnOutput = runTurn(
    engineState,
    {
      heard: transcript,
      candidates: [
        { roleID: 'coherence-seeking', text: coh.text },
        { roleID: 'displacement-seeking', text: disp.text },
      ],
      embeddings,
      draw,
      spectralState: 'absent',
      allowSynthesis: embeddingMode === 'live',
    },
    tuning,
  );
  timing.gateMs = deps.nowMs() - gateStart;
  timing.promptTokens = (coh.promptTokens ?? 0) + (disp.promptTokens ?? 0);
  timing.completionTokens = (coh.completionTokens ?? 0) + (disp.completionTokens ?? 0);

  const outcomeKind = turnOutput.outcome.kind;
  deps.dispatch({
    type: 'GATED',
    outcome: outcomeKind === 'synthesized' ? 'synthesized' : outcomeKind,
  });

  let cueSpoken = false;

  if (turnOutput.spokenText) {
    // speaking -> cooldown | error | stopped
    const speakStart = deps.nowMs();
    const speech = await deps.speak(turnOutput.spokenText, turnOutput.prosody);
    timing.ttsDurationMs = speech.durationMs;
    timing.processingToSpeechMs = speakStart - turnStart;
    if (!deps.isCurrent()) return stale();
    if (speech.cancelled) return stale();
    if (speech.error) {
      deps.dispatch({ type: 'SPEAKING_FAILED', reason: 'TTS error' });
      timing.outcome = 'tts-error';
      timing.turnTotalMs = deps.nowMs() - turnStart;
      return { status: 'error', errorReason: 'TTS error', timing, turnOutput, draw, cueSpoken };
    }
    deps.dispatch({ type: 'SPEAKING_DONE' });
  } else {
    // silent -> (cue?) -> cooldown
    const capped = engineState.consecutiveSilence >= tuning.maxConsecutiveSilence;
    if (capped && req.silenceCueText) {
      deps.dispatch({ type: 'SILENCE_CUE' });
      const speech = await deps.speak(req.silenceCueText, {});
      cueSpoken = true;
      engineState.consecutiveSilence = 0;
      if (!deps.isCurrent()) return stale();
      if (speech.cancelled) return stale();
      if (speech.error) {
        deps.dispatch({ type: 'SPEAKING_FAILED', reason: 'TTS error during cue' });
        timing.outcome = 'tts-error';
        timing.turnTotalMs = deps.nowMs() - turnStart;
        return { status: 'error', errorReason: 'TTS error during cue', timing, turnOutput, draw, cueSpoken };
      }
      deps.dispatch({ type: 'CUE_DONE' });
    } else {
      deps.dispatch({ type: 'SILENCE_DONE' });
    }
  }

  timing.outcome = outcomeKind;
  timing.turnTotalMs = deps.nowMs() - turnStart;
  return { status: 'complete', turnOutput, draw, timing, cueSpoken };
}
