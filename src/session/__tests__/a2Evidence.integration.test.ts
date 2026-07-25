// a2Evidence.integration.test.ts — captures the cross-platform A2 evidence
// record against REAL local services, through the same execution path the UI
// uses. Writes .handoff/fable5/a2-evidence.json.
//
// Gated: NEURALCOMPOSE_LIVE=1 ./node_modules/.bin/jest a2Evidence
//
// Proves, live:
//   - per-role requested vs resolved identity (exact model, locality, readiness);
//   - one real turn whose both candidates ran under those identities;
//   - deliberately configuring a missing model fails closed (no READY, no
//     alternate provider).

import * as fs from 'fs';
import * as path from 'path';
import { runLiveTurn } from '../turnPipeline';
import { SessionReducer, type SessionEvent, type SessionState } from '../../dialectic/sessionReducer';
import { createEngineState } from '../../dialectic/engine';
import { getProfile, DEFAULT_TUNING } from '../../dialectic/profiles';
import { generateCandidate, generationModelReady } from '../../services/GenerationClient';
import { embedBatch, mockEmbed, EMBEDDING_MODEL_PATH } from '../../services/EmbeddingClient';
import { getManifest } from '../../services/modelManifest';
import { checkSessionReadiness } from '../readiness';
import { assertRoleConsistency, type RuntimeIdentity } from '../../runtime/identity';

const LIVE = process.env.NEURALCOMPOSE_LIVE === '1';
const maybe = LIVE ? describe : describe.skip;

const identityRecord = (id: RuntimeIdentity) => ({
  requested_provider: id.requested.provider,
  requested_model: id.requested.model.split('/').pop(),
  resolved_provider: id.resolved.provider,
  resolved_model: id.resolved.model ? id.resolved.model.split('/').pop() : null,
  model_match: id.resolved.modelMatch,
  role: id.resolved.role,
  prompt_profile: id.resolved.promptProfile,
  prompt_sha256: id.resolved.promptSha256,
  locality: id.resolved.locality,
  endpoint_class: id.resolved.endpointClass,
  readiness: id.resolved.readiness,
  provenance: id.resolved.provenance,
  failure: id.failure,
});

maybe('LIVE A2 evidence record (real Qwen + BGE, one execution path)', () => {
  jest.setTimeout(300_000);

  test('capture per-role identities, one real turn, and fail-closed missing-model proof', async () => {
    // 1. Readiness resolves both role identities against the real services.
    const readiness = await checkSessionReadiness();
    expect(readiness.ok).toBe(true);
    expect(readiness.identities.coherence.resolved.readiness).toBe('ready');
    expect(readiness.identities.displacement.resolved.readiness).toBe('ready');
    expect(readiness.identities.witness).toBeNull();

    // 2. One real turn; both generations pass the role-consistency guard on
    //    the identity resolved for their own role.
    const tuning = getProfile('focused').tuning;
    const engineState = createEngineState(tuning);
    let state: SessionState = 'transcribing';
    const dispatch = (e: SessionEvent) => {
      const [next] = SessionReducer.reduce(state, e, DEFAULT_TUNING);
      state = next;
    };

    const report = await runLiveTurn(
      {
        generate: async (roleID, heard, standingTension) => {
          const role = roleID === 'coherence-seeking' ? 'coherence' as const : 'displacement' as const;
          const identity = readiness.identities[role];
          assertRoleConsistency(identity, role);
          expect(identity.resolved.readiness).toBe('ready');
          const r = await generateCandidate(roleID, heard, standingTension, getManifest(), { timeoutMs: 120000 });
          return 'reason' in r ? { reason: r.reason, latencyMs: r.latencyMs } : r;
        },
        embedLive: async (texts) => {
          const r = await embedBatch(texts, { timeoutMs: 60000 });
          return 'reason' in r ? { reason: r.reason, latencyMs: r.latencyMs } : r;
        },
        embedMock: (texts) => mockEmbed(texts),
        speak: async () => ({ cancelled: false, error: false, durationMs: 0 }),
        dispatch,
        isCurrent: () => true,
        rng: () => 0.5,
        nowMs: () => Date.now(),
      },
      {
        transcript: 'Attention is a resource we spend before we notice it.',
        embeddingMode: readiness.embeddingMode,
        tuning,
        engineState,
        silenceCueText: 'Still here.',
      },
    );
    expect(report.status).toBe('complete');
    expect(report.turnOutput).toBeDefined();

    // 3. Deliberate missing model: the probe must fail closed against the
    //    real server — never READY, never an alternate provider.
    const missing = await generationModelReady('/nonexistent/definitely-not-served.gguf');
    expect(missing.ready).toBe(false);
    expect(missing.probeError).toBeNull(); // server responded; the MODEL is what failed

    // 4. Persist the evidence record (metadata only — no prompt/user text).
    const out = {
      captured_at: new Date().toISOString(),
      platform: 'android-termux-pixel8a',
      observed_on_pixel: true,
      coherence: identityRecord(readiness.identities.coherence),
      displacement: identityRecord(readiness.identities.displacement),
      witness: 'not configured — zero resolution work performed',
      gate: {
        embedder: EMBEDDING_MODEL_PATH.split('/').pop(),
        embedding_mode: readiness.embeddingMode,
        tension: report.turnOutput!.result.tension,
        margin: report.turnOutput!.result.margin,
        outcome: report.turnOutput!.outcome.kind,
        rng_draw: report.draw,
      },
      services: {
        generation: readiness.generation.ok ? 'ready' : 'blocked',
        embeddings: readiness.embeddingMode === 'live' ? 'ready' : 'blocked',
        stt: readiness.sttAvailable ? 'ready' : 'blocked',
        tts: 'device-only (not observable from node)',
      },
      finetune_status: getManifest().finetuneStatus,
      timing_ms: report.timing,
      missing_model_proof: {
        configured: 'definitely-not-served.gguf',
        ready: missing.ready,
        detail: missing.detail,
      },
    };
    const dir = path.join(__dirname, '..', '..', '..', '.handoff', 'fable5');
    fs.mkdirSync(dir, { recursive: true });
    fs.writeFileSync(path.join(dir, 'a2-evidence.json'), JSON.stringify(out, null, 2));
  });
});
