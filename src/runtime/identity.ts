// identity.ts — immutable runtime identity, separate from the client that
// performs generation (upstream A2 delta, Apple PR #32 parity).
//
// A configured URL and model string are only a REQUEST. The RESOLVED side
// records what a positive probe actually established. The identity exists on
// success AND failure paths, so provider substitution, model mismatch, and
// role/prompt confusion are observable instead of inferable.
//
// Cross-platform terminology (Apple → Android):
//   ResolvedRuntimeIdentity → RuntimeIdentity
//   RuntimeRole             → GeneratorRole
//   RuntimeIdentityPresentation → deriveRuntimePresentation()

export type GeneratorRole = 'coherence' | 'displacement' | 'witness';

/** Where inference and user text actually go — not where the process runs. */
export type RuntimeLocality =
  | 'on_device'
  | 'localhost_local_inference'
  | 'local_broker_to_remote_service'
  | 'remote_service'
  | 'unknown';

export type RuntimeReadiness = 'ready' | 'not_ready' | 'unverified';

/** How the probed model id relates to the configured one. */
export type ModelMatch = 'exact' | 'alias' | 'none';

export type FinetuneStatus = 'baseline' | 'adapter' | 'merged' | 'unverified';

export interface RequestedRuntime {
  provider: string;
  /** Configured model reference (full path allowed internally; sanitize for display). */
  model: string;
  role: GeneratorRole;
  endpoint: string;
}

export interface ResolvedRuntime {
  provider: string;
  /** Model id the service positively reported, or null when resolution failed. */
  model: string | null;
  role: GeneratorRole;
  locality: RuntimeLocality;
  readiness: RuntimeReadiness;
  modelMatch: ModelMatch;
  promptProfile: string;
  promptSha256: string | null;
  /** Transport class safe for display: 'loopback-http', 'remote-http', 'unknown'. */
  endpointClass: string;
  provenance: FinetuneStatus;
}

export interface RuntimeResolutionFailure {
  category:
    | 'endpoint_unreachable'
    | 'model_missing'
    | 'model_mismatch'
    | 'prompt_missing'
    | 'role_mismatch';
  /** Sanitized — never contains absolute paths, tokens, or PATH detail. */
  publicMessage: string;
}

export interface RuntimeIdentity {
  requested: RequestedRuntime;
  resolved: ResolvedRuntime;
  failure: RuntimeResolutionFailure | null;
}

/** Loopback hosts: traffic cannot leave the device. */
const LOOPBACK_HOSTS = new Set(['127.0.0.1', 'localhost', '::1', '[::1]']);

export function endpointHost(url: string): string | null {
  const m = /^[a-z][a-z0-9+.-]*:\/\/([^/:?#]+|\[[^\]]+\])/i.exec(url.trim());
  return m ? m[1].toLowerCase() : null;
}

/**
 * Classify endpoint locality. A loopback endpoint alone does NOT prove local
 * inference — a local executable may broker remote inference — so loopback
 * only resolves to `localhost_local_inference` when the probe positively
 * matched the configured on-device model artifact (`modelMatch === 'exact'`).
 * Loopback without that proof stays `unknown` (displayed as EGRESS UNVERIFIED).
 */
export function classifyLocality(url: string, modelMatch: ModelMatch): RuntimeLocality {
  const host = endpointHost(url);
  if (!host) return 'unknown';
  if (LOOPBACK_HOSTS.has(host)) {
    return modelMatch === 'exact' ? 'localhost_local_inference' : 'unknown';
  }
  return 'remote_service';
}

export function endpointClass(url: string): string {
  const host = endpointHost(url);
  if (!host) return 'unknown';
  return LOOPBACK_HOSTS.has(host) ? 'loopback-http' : 'remote-http';
}

/**
 * Strip anything that must not reach the UI or logs: absolute filesystem
 * paths, home-relative paths, and bearer-token-shaped strings. Keeps the
 * basename of any path so the message stays actionable.
 */
export function sanitizePublicMessage(message: string): string {
  return message
    .replace(/(?:\/[\w.@+-]+){2,}\/?/g, (p) => {
      const parts = p.split('/').filter(Boolean);
      return parts.length ? parts[parts.length - 1] : '';
    })
    .replace(/~\/[^\s"']*/g, (p) => p.split('/').pop() ?? '')
    .replace(/\b(bearer|token|key|secret)[=:\s]+\S+/gi, '$1=<redacted>')
    .trim();
}

const baseName = (ref: string) => ref.split('/').pop() ?? ref;

/**
 * Exact match means the reported id names the same model artifact as the
 * configured reference (full path or identical basename). A looser overlap
 * (alias/tag/substring) is 'alias' — enough to know the server is not serving
 * a different model family, NOT enough to claim verified provenance or READY.
 */
export function classifyModelMatch(configuredModel: string, reportedIds: string[]): ModelMatch {
  if (reportedIds.length === 0) return 'none';
  const expected = baseName(configuredModel);
  if (reportedIds.some((id) => id === configuredModel || baseName(id) === expected)) return 'exact';
  const found = reportedIds.some(
    (id) => id.includes(expected) || expected.includes(baseName(id)),
  );
  return found ? 'alias' : 'none';
}

export interface GenerationProbeInput {
  role: GeneratorRole;
  provider: string;
  configuredModel: string;
  endpoint: string;
  /** Model ids the service positively reported (empty on failure/unreachable). */
  reportedModelIds: string[];
  /** Null when the endpoint responded; a reason string when it did not. */
  probeError: string | null;
  promptProfile: string;
  /** Null/empty prompt is a typed readiness failure, never an empty string sent. */
  promptSha256: string | null;
  manifestProvenance: FinetuneStatus;
}

/**
 * Build the immutable per-role identity from probe evidence. Never throws:
 * failure paths return an identity with `readiness: 'not_ready'` (or
 * `'unverified'` for alias-only matches) and a sanitized failure record.
 */
export function resolveRuntimeIdentity(input: GenerationProbeInput): RuntimeIdentity {
  const requested: RequestedRuntime = {
    provider: input.provider,
    model: input.configuredModel,
    role: input.role,
    endpoint: input.endpoint,
  };

  const match = input.probeError ? 'none' : classifyModelMatch(input.configuredModel, input.reportedModelIds);
  const locality = classifyLocality(input.endpoint, match);
  const promptOk = !!input.promptSha256;

  let readiness: RuntimeReadiness;
  let failure: RuntimeResolutionFailure | null = null;

  if (input.probeError) {
    readiness = 'not_ready';
    failure = {
      category: 'endpoint_unreachable',
      publicMessage: sanitizePublicMessage(`generation endpoint not reachable: ${input.probeError}`),
    };
  } else if (match === 'none') {
    readiness = 'not_ready';
    const loaded = input.reportedModelIds.map(baseName).join(', ') || 'none';
    failure = {
      category: input.reportedModelIds.length === 0 ? 'model_missing' : 'model_mismatch',
      publicMessage: sanitizePublicMessage(
        `configured model "${baseName(input.configuredModel)}" not served (loaded: ${loaded})`,
      ),
    };
  } else if (!promptOk) {
    readiness = 'not_ready';
    failure = {
      category: 'prompt_missing',
      publicMessage: `prompt resource for role "${input.role}" is missing or empty`,
    };
  } else if (match === 'alias') {
    // Served model overlaps the configured name but is not provably the same
    // artifact — provenance cannot be established, so the session may not
    // claim READY on it.
    readiness = 'unverified';
    failure = {
      category: 'model_mismatch',
      publicMessage: sanitizePublicMessage(
        `served model "${baseName(input.reportedModelIds[0] ?? '')}" is an alias of ` +
        `"${baseName(input.configuredModel)}" — provenance unverified`,
      ),
    };
  } else {
    readiness = 'ready';
  }

  const resolved: ResolvedRuntime = {
    provider: input.provider,
    model: match === 'none' ? null : (input.reportedModelIds[0] ?? null),
    role: input.role,
    locality,
    readiness,
    modelMatch: match,
    promptProfile: input.promptProfile,
    promptSha256: input.promptSha256,
    endpointClass: endpointClass(input.endpoint),
    provenance: readiness === 'ready' ? input.manifestProvenance : 'unverified',
  };

  return { requested, resolved, failure };
}

/**
 * Role-consistency guard: a runtime resolved for one role must never be used
 * for another. Fails closed (throws) — callers treat this as a turn error,
 * never as something to paper over.
 */
export function assertRoleConsistency(identity: RuntimeIdentity, useRole: GeneratorRole): void {
  if (identity.resolved.role !== useRole || identity.requested.role !== useRole) {
    throw new Error(
      `role mismatch: runtime resolved for "${identity.resolved.role}" supplied to "${useRole}"`,
    );
  }
}

export interface RuntimePresentation {
  providerBadge: string;
  modelBadge: string;
  roleLabel: string;
  localityLabel: string;
  egressLabel: string;
  readinessLabel: string;
  provenanceBadge: string;
}

/**
 * The UI derives every badge from the resolved identity — no hard-coded
 * LOCAL / ON-DEVICE / QWEN / READY / NO EGRESS strings in components.
 * Defaults are conservative: unknown locality reads EGRESS UNVERIFIED,
 * unknown provenance reads UNVERIFIED, missing model/prompt reads NOT READY.
 */
export function deriveRuntimePresentation(identity: RuntimeIdentity): RuntimePresentation {
  const r = identity.resolved;

  const localityLabels: Record<RuntimeLocality, string> = {
    on_device: 'ON-DEVICE',
    localhost_local_inference: 'LOCALHOST (LOCAL INFERENCE)',
    local_broker_to_remote_service: 'LOCAL BROKER → REMOTE',
    remote_service: 'REMOTE SERVICE',
    unknown: 'LOCALITY UNKNOWN',
  };
  const egressLabels: Record<RuntimeLocality, string> = {
    on_device: 'NO EGRESS',
    localhost_local_inference: 'NO EGRESS',
    local_broker_to_remote_service: 'EGRESS: REMOTE INFERENCE',
    remote_service: 'EGRESS: REMOTE SERVICE',
    unknown: 'EGRESS UNVERIFIED',
  };

  const readinessLabel =
    r.readiness === 'ready' ? 'READY'
    : r.readiness === 'unverified' ? 'UNVERIFIED'
    : 'NOT READY';

  const provenanceBadge =
    r.readiness !== 'ready' ? 'UNVERIFIED'
    : r.provenance === 'baseline' ? 'BASELINE'
    : r.provenance === 'adapter' ? 'ADAPTER'
    : r.provenance === 'merged' ? 'MERGED'
    : 'UNVERIFIED';

  return {
    providerBadge: identity.requested.provider,
    modelBadge: r.model ? baseName(r.model) : `${baseName(identity.requested.model)} (missing)`,
    roleLabel: r.role,
    localityLabel: localityLabels[r.locality],
    egressLabel: egressLabels[r.locality],
    readinessLabel,
    provenanceBadge,
  };
}
