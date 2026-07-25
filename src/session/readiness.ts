// readiness.ts — fail-closed session readiness (upstream PRs #29/#31 invariants,
// extended with A2 runtime identity, Apple PR #32 parity).
// A session may enter READY only when:
//   - every prompt resource is present and non-empty;
//   - the generation server positively reports the EXACT configured Qwen model
//     (an alias-only overlap is UNVERIFIED, not ready).
// Embedding and STT are graded, not gating: their absence degrades the session
// to clearly-labeled MOCK gates / text-injection-only, it never substitutes a
// provider. Discovering a missing model at first generation is a defect.
//
// Each enabled role resolves to its own immutable RuntimeIdentity — on success
// AND failure — carrying requested vs resolved provider/model, locality,
// readiness, prompt profile + SHA-256, and a sanitized failure record. The
// Witness role is not configured on Android: it resolves nothing and performs
// zero prompt loads, model checks, endpoint probes, or generation work.

import { promptResourcesReady, rolePromptManifest, PROMPT_PROFILE } from '../dialectic/prompts';
import { generationModelReady } from '../services/GenerationClient';
import { embeddingAlive } from '../services/EmbeddingClient';
import { sttAlive } from '../services/TranscriptionClient';
import { getManifest } from '../services/modelManifest';
import { LLM_URL } from '../config';
import {
  resolveRuntimeIdentity,
  sanitizePublicMessage,
  type RuntimeIdentity,
  type GeneratorRole,
} from '../runtime/identity';

export const GENERATION_PROVIDER = 'llama-server';

export interface SessionReadiness {
  /** True only when prompts and the generation model are positively verified. */
  ok: boolean;
  /** Human-readable reasons when not ok. */
  reasons: string[];
  generation: { ok: boolean; detail: string };
  prompts: { ok: boolean; detail: string };
  /** Live embedding service available → 'live'; otherwise MOCK gates. */
  embeddingMode: 'live' | 'mock';
  /** Whether the microphone → STT path may be offered. */
  sttAvailable: boolean;
  promptProfile: typeof PROMPT_PROFILE;
  /**
   * Per-role runtime identities (requested vs resolved). Present on success
   * and failure alike. `witness` is null because the role is not configured —
   * null here means zero resolution work was performed, not a hidden runtime.
   */
  identities: {
    coherence: RuntimeIdentity;
    displacement: RuntimeIdentity;
    witness: null;
  };
}

export async function checkSessionReadiness(): Promise<SessionReadiness> {
  const prompts = promptResourcesReady();
  const manifest = getManifest();
  const [probe, embOk, sttOk] = await Promise.all([
    generationModelReady(manifest.baseGgufPath),
    embeddingAlive(),
    sttAlive(),
  ]);

  const identityFor = (role: Exclude<GeneratorRole, 'witness'>): RuntimeIdentity => {
    const promptManifest = rolePromptManifest(role);
    return resolveRuntimeIdentity({
      role,
      provider: GENERATION_PROVIDER,
      configuredModel: manifest.baseGgufPath,
      endpoint: LLM_URL,
      reportedModelIds: probe.reportedModelIds,
      probeError: probe.probeError,
      promptProfile: promptManifest.profile,
      promptSha256: prompts.ok ? promptManifest.sha256 : null,
      manifestProvenance: manifest.finetuneStatus,
    });
  };

  const identities = {
    coherence: identityFor('coherence'),
    displacement: identityFor('displacement'),
    witness: null,
  } as const;

  const rolesReady =
    identities.coherence.resolved.readiness === 'ready' &&
    identities.displacement.resolved.readiness === 'ready';

  const reasons: string[] = [];
  if (!prompts.ok) reasons.push(prompts.detail);
  // Probe details may quote served model paths — sanitize before they can
  // reach the UI or logs (A2: public errors carry no private filesystem detail).
  if (!probe.ready) reasons.push(sanitizePublicMessage(`Qwen not ready: ${probe.detail}`));
  for (const role of ['coherence', 'displacement'] as const) {
    const f = identities[role].failure;
    if (f && !reasons.some((r) => r.includes(f.publicMessage))) {
      reasons.push(`${role}: ${f.publicMessage}`);
    }
  }

  return {
    ok: prompts.ok && probe.ready && rolesReady,
    reasons,
    generation: { ok: probe.ready, detail: sanitizePublicMessage(probe.detail) },
    prompts,
    embeddingMode: embOk ? 'live' : 'mock',
    sttAvailable: sttOk,
    promptProfile: PROMPT_PROFILE,
    identities,
  };
}
