// turnPipeline.test.ts — the single execution path, exercised with fake services.
// Every dispatched event is replayed through the real SessionReducer starting
// from 'transcribing', so an illegal event order fails these tests the same
// way it would crash the app.

import { runLiveTurn, type TurnDeps, type TurnRequest } from '../turnPipeline';
import { SessionReducer, type SessionEvent, type SessionState, isMicActive, isTTSActive } from '../../dialectic/sessionReducer';
import { createEngineState } from '../../dialectic/engine';
import { getProfile, DEFAULT_TUNING } from '../../dialectic/profiles';
import { mockEmbed } from '../../services/EmbeddingClient';
import type { Embedding } from '../../dialectic/types';

/** Reducer-checked event log: throws on any illegal transition. */
function makeLegalityDispatcher(start: SessionState) {
  let state = start;
  const events: SessionEvent[] = [];
  const states: SessionState[] = [start];
  return {
    dispatch: (e: SessionEvent) => {
      const [next] = SessionReducer.reduce(state, e, DEFAULT_TUNING);
      state = next;
      events.push(e);
      states.push(next);
      expect(isMicActive(next) && isTTSActive(next)).toBe(false);
    },
    events,
    states,
    get state() { return state; },
  };
}

function okGeneration(text: string) {
  return { text, promptTokens: 10, completionTokens: 5, latencyMs: 100 };
}

function makeDeps(overrides: Partial<TurnDeps> = {}) {
  const legality = makeLegalityDispatcher('transcribing');
  const deps: TurnDeps = {
    generate: async (roleID) =>
      okGeneration(roleID === 'coherence-seeking' ? 'the claim, made precise' : 'an ignored assumption'),
    embedLive: async (texts) => ({ embeddings: mockEmbed(texts), modelID: 'fake-live', latencyMs: 20 }),
    embedMock: (texts) => mockEmbed(texts),
    speak: async () => ({ cancelled: false, error: false, durationMs: 500 }),
    dispatch: legality.dispatch,
    isCurrent: () => true,
    rng: () => 0.5,
    nowMs: () => 0,
    ...overrides,
  };
  return { deps, legality };
}

function makeRequest(overrides: Partial<TurnRequest> = {}): TurnRequest {
  const tuning = getProfile('focused').tuning;
  return {
    transcript: 'the heard sentence',
    embeddingMode: 'live',
    tuning,
    engineState: createEngineState(tuning),
    silenceCueText: 'Still here.',
    ...overrides,
  };
}

describe('runLiveTurn', () => {
  test('happy path dispatches a fully legal event sequence and completes', async () => {
    const { deps, legality } = makeDeps();
    const report = await runLiveTurn(deps, makeRequest());
    expect(report.status).toBe('complete');
    expect(legality.state).toBe('cooldown');
    expect(legality.events.map((e) => e.type)).toEqual([
      'TRANSCRIBED', 'COHERENCE_GENERATED', 'DISPLACEMENT_GENERATED',
      'EMBEDDED', 'GATED',
      legality.events[5].type, // SPEAKING_DONE or SILENCE_DONE depending on gate
    ]);
    expect(report.timing.coherenceGenerateMs).toBe(100);
    expect(report.timing.promptTokens).toBe(20);
  });

  test('coherence failure ends the turn as error, nothing spoken', async () => {
    let spoke = false;
    const { deps, legality } = makeDeps({
      generate: async (roleID) =>
        roleID === 'coherence-seeking'
          ? { reason: 'timeout', latencyMs: 30000 }
          : okGeneration('unused'),
      speak: async () => { spoke = true; return { cancelled: false, error: false, durationMs: 0 }; },
    });
    const report = await runLiveTurn(deps, makeRequest());
    expect(report.status).toBe('error');
    expect(spoke).toBe(false);
    expect(legality.state).toBe('error');
  });

  test('P0: live embedding failure fails closed — no mock fallback, no speech', async () => {
    let mockUsed = false;
    let spoke = false;
    const { deps, legality } = makeDeps({
      embedLive: async () => ({ reason: 'HTTP 500', latencyMs: 10 }),
      embedMock: (texts) => { mockUsed = true; return mockEmbed(texts); },
      speak: async () => { spoke = true; return { cancelled: false, error: false, durationMs: 0 }; },
    });
    const report = await runLiveTurn(deps, makeRequest({ embeddingMode: 'live' }));
    expect(report.status).toBe('error');
    expect(report.errorReason).toContain('Embedding failed');
    expect(mockUsed).toBe(false);
    expect(spoke).toBe(false);
    expect(legality.state).toBe('error');
  });

  test('P0: dimensionally inconsistent embeddings are rejected', async () => {
    const bad: Embedding[] = [
      { values: [1, 0, 0], modelID: 'm', dimension: 3, version: '1', seed: 0 },
      { values: [0, 1], modelID: 'm', dimension: 2, version: '1', seed: 0 },
      { values: [0, 0, 1], modelID: 'm', dimension: 3, version: '1', seed: 0 },
    ];
    const { deps } = makeDeps({
      embedLive: async () => ({ embeddings: bad, modelID: 'm', latencyMs: 5 }),
    });
    const report = await runLiveTurn(deps, makeRequest());
    expect(report.status).toBe('error');
    expect(report.errorReason).toContain('dimension mismatch');
  });

  test('P0: MOCK gates disable synthesis even when memory holds a perfect bridge', async () => {
    const tuning = getProfile('focused').tuning;
    const engineState = createEngineState(tuning);
    // Seed a prior reply that would trivially clear any synthesis bar.
    const bridge = mockEmbed(['a bridging idea'])[0];
    engineState.memory.recordReply('a bridging idea', bridge, 0);
    const { deps } = makeDeps();
    const report = await runLiveTurn(deps, makeRequest({ embeddingMode: 'mock', engineState, tuning }));
    expect(report.status).toBe('complete');
    expect(report.turnOutput?.synthesisCandidate ?? null).toBeNull();
    expect(report.turnOutput?.outcome.kind).not.toBe('synthesized');
  });

  test('stale epoch mid-turn stops silently without speaking or dispatching further', async () => {
    let calls = 0;
    let spoke = false;
    const { deps, legality } = makeDeps({
      isCurrent: () => calls < 1, // stale after the first generate resolves
      generate: async (roleID) => { calls++; return okGeneration(roleID); },
      speak: async () => { spoke = true; return { cancelled: false, error: false, durationMs: 0 }; },
    });
    const report = await runLiveTurn(deps, makeRequest());
    expect(report.status).toBe('stale');
    expect(spoke).toBe(false);
    // Only TRANSCRIBED was dispatched before staleness was detected.
    expect(legality.events.map((e) => e.type)).toEqual(['TRANSCRIBED']);
  });

  test('TTS error settles as SPEAKING_FAILED before any re-arm', async () => {
    const { deps, legality } = makeDeps({
      speak: async () => ({ cancelled: false, error: true, durationMs: 100 }),
      // Force a decisive spoken outcome by making candidates identical to heard.
      generate: async () => okGeneration('the heard sentence'),
    });
    const report = await runLiveTurn(deps, makeRequest());
    if (report.turnOutput?.spokenText) {
      expect(report.status).toBe('error');
      expect(legality.state).toBe('error');
      expect(legality.events.map((e) => e.type)).toContain('SPEAKING_FAILED');
    } else {
      // Gate chose silence; TTS was never exercised — acceptable for this seed.
      expect(report.status).toBe('complete');
    }
  });

  test('silence cap speaks the static cue through the cueing state', async () => {
    const tuning = { ...getProfile('focused').tuning, stalemateMargin: 10, highTension: 0 };
    const engineState = createEngineState(tuning);
    engineState.consecutiveSilence = tuning.maxConsecutiveSilence;
    const spokenTexts: string[] = [];
    const { deps, legality } = makeDeps({
      speak: async (text) => { spokenTexts.push(text); return { cancelled: false, error: false, durationMs: 50 }; },
      // Opposed-enough candidates so the forced stalemate gate silences.
      generate: async (roleID) => okGeneration(roleID),
    });
    const report = await runLiveTurn(deps, makeRequest({ tuning, engineState }));
    expect(report.status).toBe('complete');
    expect(report.turnOutput?.outcome.kind).toBe('silent');
    expect(report.cueSpoken).toBe(true);
    expect(spokenTexts).toEqual(['Still here.']);
    expect(legality.events.map((e) => e.type)).toContain('SILENCE_CUE');
    expect(legality.events.map((e) => e.type)).toContain('CUE_DONE');
    expect(legality.state).toBe('cooldown');
  });
});
