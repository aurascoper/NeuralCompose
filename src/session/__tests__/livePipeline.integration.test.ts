// livePipeline.integration.test.ts — the P1 vertical slice against REAL local
// services (Qwen llama-server:8081 + BGE llama-server:8082), through the same
// runLiveTurn path the UI uses. TTS is a recorded no-op here (node has no
// Android TTS); audible speech remains device-only evidence.
//
// Gated: runs only when NEURALCOMPOSE_LIVE=1 and the services are up.
//   NEURALCOMPOSE_LIVE=1 ./node_modules/.bin/jest livePipeline

import { runLiveTurn } from '../turnPipeline';
import { SessionReducer, type SessionEvent, type SessionState } from '../../dialectic/sessionReducer';
import { createEngineState } from '../../dialectic/engine';
import { getProfile, DEFAULT_TUNING } from '../../dialectic/profiles';
import { generateCandidate } from '../../services/GenerationClient';
import { embedBatch, mockEmbed } from '../../services/EmbeddingClient';
import { getManifest } from '../../services/modelManifest';
import { checkSessionReadiness } from '../readiness';

const LIVE = process.env.NEURALCOMPOSE_LIVE === '1';
const maybe = LIVE ? describe : describe.skip;

function legalityDispatcher(start: SessionState) {
  let state = start;
  const events: SessionEvent[] = [];
  return {
    dispatch: (e: SessionEvent) => {
      const [next] = SessionReducer.reduce(state, e, DEFAULT_TUNING);
      state = next;
      events.push(e);
    },
    events,
    get state() { return state; },
  };
}

maybe('LIVE P1 vertical slice (real Qwen + real BGE, one execution path)', () => {
  jest.setTimeout(180_000);

  test('readiness gate passes fail-closed checks against real services', async () => {
    const r = await checkSessionReadiness();
    expect(r.prompts.ok).toBe(true);
    expect(r.generation.ok).toBe(true);
    expect(r.embeddingMode).toBe('live');
  });

  test('a full live turn completes with real generations and live gates', async () => {
    const tuning = getProfile('focused').tuning;
    const engineState = createEngineState(tuning);
    const legality = legalityDispatcher('transcribing');
    const spoken: Array<{ text: string; prosody: object }> = [];

    const report = await runLiveTurn(
      {
        generate: async (roleID, heard, standingTension) => {
          const r = await generateCandidate(roleID, heard, standingTension, getManifest(), { timeoutMs: 60000 });
          return 'reason' in r ? { reason: r.reason, latencyMs: r.latencyMs } : r;
        },
        embedLive: async (texts) => {
          const r = await embedBatch(texts, { timeoutMs: 30000 });
          return 'reason' in r ? { reason: r.reason, latencyMs: r.latencyMs } : r;
        },
        embedMock: (texts) => mockEmbed(texts),
        speak: async (text, prosody) => {
          spoken.push({ text, prosody });
          return { cancelled: false, error: false, durationMs: 0 };
        },
        dispatch: legality.dispatch,
        isCurrent: () => true,
        rng: () => 0.5,
        nowMs: () => Date.now(),
      },
      {
        transcript: 'Habits shape identity more than goals do.',
        embeddingMode: 'live',
        tuning,
        engineState,
        silenceCueText: 'Still here.',
      },
    );

    // eslint-disable-next-line no-console
    console.log(JSON.stringify({
      status: report.status,
      outcome: report.turnOutput?.outcome.kind,
      tension: report.turnOutput?.result.tension,
      margin: report.turnOutput?.result.margin,
      timing: report.timing,
      spokenCount: spoken.length,
      prosody: spoken[0]?.prosody,
      events: legality.events.map((e) => e.type),
      endState: legality.state,
    }, null, 2));

    expect(report.status).toBe('complete');
    expect(['spoke', 'silent', 'synthesized']).toContain(report.turnOutput?.outcome.kind);
    expect(report.timing.coherenceGenerateMs).toBeGreaterThan(0);
    expect(report.timing.displacementGenerateMs).toBeGreaterThan(0);
    expect(report.timing.embeddingMs).toBeGreaterThan(0);
    expect(legality.state).toBe('cooldown');
  });
});
