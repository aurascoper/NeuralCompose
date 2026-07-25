// readinessIdentity.test.ts — A2 delta regressions at the real readiness call
// site: missing exact model disables the loop, no alternate provider is
// contacted, identities exist on failure, per-role prompt hashes are distinct,
// public reasons carry no private filesystem detail.

import { checkSessionReadiness } from '../readiness';
import { getManifest } from '../../services/modelManifest';
import { rolePromptManifest } from '../../dialectic/prompts';

const QWEN_PATH = getManifest().baseGgufPath;
const QWEN_BASE = QWEN_PATH.split('/').pop() as string;

/** Fetch mock: routes by URL, records every contacted host. */
function mockFetch(handlers: {
  models?: () => Promise<Response> | Response;
}) {
  const contacted: string[] = [];
  const fetchImpl = async (input: any): Promise<Response> => {
    const url = String(input);
    contacted.push(url);
    const host = /:\/\/([^/:]+)/.exec(url)?.[1] ?? '';
    if (!['127.0.0.1', 'localhost', '::1'].includes(host)) {
      throw new Error(`test fail-safe: non-loopback host contacted: ${host}`);
    }
    if (url.includes(':8081/v1/models') && handlers.models) {
      return handlers.models();
    }
    // Embedding (:8082) and STT (:8083) probes are down in these scenarios.
    throw new Error('ECONNREFUSED');
  };
  return { contacted, fetchImpl };
}

const jsonResponse = (body: unknown, ok = true): Response =>
  ({ ok, status: ok ? 200 : 500, json: async () => body } as unknown as Response);

describe('checkSessionReadiness — A2 runtime identity at the call site', () => {
  const realFetch = global.fetch;
  afterEach(() => { global.fetch = realFetch; });

  test('exact model served: READY with per-role identities and localhost locality', async () => {
    const { fetchImpl } = mockFetch({
      models: () => jsonResponse({ data: [{ id: QWEN_PATH }] }),
    });
    global.fetch = fetchImpl as typeof fetch;

    const r = await checkSessionReadiness();
    expect(r.ok).toBe(true);
    expect(r.identities.coherence.resolved.readiness).toBe('ready');
    expect(r.identities.displacement.resolved.readiness).toBe('ready');
    expect(r.identities.coherence.resolved.locality).toBe('localhost_local_inference');
    expect(r.identities.witness).toBeNull();
    // Two poles share one server but keep distinct role identities and hashes.
    expect(r.identities.coherence.resolved.role).toBe('coherence');
    expect(r.identities.displacement.resolved.role).toBe('displacement');
    expect(r.identities.coherence.resolved.promptSha256)
      .not.toBe(r.identities.displacement.resolved.promptSha256);
    expect(r.identities.coherence.resolved.promptSha256)
      .toBe(rolePromptManifest('coherence').sha256);
    // Embedding/STT down degrades, never substitutes.
    expect(r.embeddingMode).toBe('mock');
    expect(r.sttAvailable).toBe(false);
  });

  test('missing exact model: session NOT ready, identity exists with failure, no alternate provider', async () => {
    const { contacted, fetchImpl } = mockFetch({
      models: () => jsonResponse({ data: [{ id: '/elsewhere/other-model.gguf' }] }),
    });
    global.fetch = fetchImpl as typeof fetch;

    const r = await checkSessionReadiness();
    expect(r.ok).toBe(false);
    expect(r.generation.ok).toBe(false);
    const id = r.identities.coherence;
    expect(id.resolved.readiness).toBe('not_ready');
    expect(id.resolved.model).toBeNull();
    expect(id.failure?.category).toBe('model_mismatch');
    expect(id.requested.model).toBe(QWEN_PATH);
    // Sanitized reasons: no absolute private paths reach the UI.
    for (const reason of r.reasons) {
      expect(reason).not.toContain('/data/data');
      expect(reason).not.toContain('/elsewhere');
    }
    expect(r.reasons.join(' ')).toContain(QWEN_BASE);
    // Every contacted endpoint is loopback: no cloud, no substitution.
    expect(contacted.length).toBeGreaterThan(0);
    for (const url of contacted) {
      expect(url).toMatch(/^http:\/\/(127\.0\.0\.1|localhost)/);
    }
  });

  test('generation endpoint unreachable: fails closed with endpoint_unreachable identity', async () => {
    global.fetch = (async () => { throw new Error('ECONNREFUSED'); }) as unknown as typeof fetch;

    const r = await checkSessionReadiness();
    expect(r.ok).toBe(false);
    expect(r.identities.coherence.failure?.category).toBe('endpoint_unreachable');
    expect(r.identities.displacement.failure?.category).toBe('endpoint_unreachable');
    expect(r.identities.coherence.resolved.locality).toBe('unknown');
  });

  test('alias-only served model: UNVERIFIED, not READY (provenance cannot be claimed)', async () => {
    const { fetchImpl } = mockFetch({
      models: () => jsonResponse({ models: [{ name: 'qwen2.5-0.5b-instruct' }] }),
    });
    global.fetch = fetchImpl as typeof fetch;

    const r = await checkSessionReadiness();
    expect(r.ok).toBe(false);
    expect(r.identities.coherence.resolved.readiness).toBe('unverified');
    expect(r.identities.coherence.resolved.provenance).toBe('unverified');
  });
});
