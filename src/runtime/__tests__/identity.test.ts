// identity.test.ts — A2 delta regressions (Apple PR #32 parity):
// requested vs resolved separation, locality classification, fail-closed
// resolution on every failure path, role-consistency guard, derived UI
// presentation, sanitized public errors.

import {
  classifyLocality,
  classifyModelMatch,
  sanitizePublicMessage,
  resolveRuntimeIdentity,
  assertRoleConsistency,
  deriveRuntimePresentation,
  endpointClass,
  type GenerationProbeInput,
} from '../identity';
import { sha256Hex } from '../sha256';

const QWEN = '/data/data/com.termux/files/home/models/qwen2.5-0.5b-instruct-q4_k_m.gguf';

function probeInput(overrides: Partial<GenerationProbeInput> = {}): GenerationProbeInput {
  return {
    role: 'coherence',
    provider: 'llama-server',
    configuredModel: QWEN,
    endpoint: 'http://127.0.0.1:8081',
    reportedModelIds: [QWEN],
    probeError: null,
    promptProfile: 'android-live-dialectic/v1',
    promptSha256: 'a'.repeat(64),
    manifestProvenance: 'baseline',
    ...overrides,
  };
}

describe('sha256Hex', () => {
  test('matches known vectors', () => {
    expect(sha256Hex('')).toBe(
      'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855');
    expect(sha256Hex('abc')).toBe(
      'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad');
    expect(sha256Hex('abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq')).toBe(
      '248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1');
  });
});

describe('classifyModelMatch', () => {
  test('exact: identical path or identical basename', () => {
    expect(classifyModelMatch(QWEN, [QWEN])).toBe('exact');
    expect(classifyModelMatch(QWEN, ['qwen2.5-0.5b-instruct-q4_k_m.gguf'])).toBe('exact');
  });
  test('alias: overlapping name is NOT exact', () => {
    expect(classifyModelMatch(QWEN, ['qwen2.5-0.5b-instruct'])).toBe('alias');
  });
  test('none: different model or nothing loaded', () => {
    expect(classifyModelMatch(QWEN, ['bge-small-en-v1.5-q8_0.gguf'])).toBe('none');
    expect(classifyModelMatch(QWEN, [])).toBe('none');
  });
});

describe('classifyLocality', () => {
  test('loopback with exact model proof is localhost_local_inference', () => {
    expect(classifyLocality('http://127.0.0.1:8081', 'exact')).toBe('localhost_local_inference');
    expect(classifyLocality('http://localhost:8081', 'exact')).toBe('localhost_local_inference');
  });
  test('loopback WITHOUT model proof stays unknown (a local broker may egress)', () => {
    expect(classifyLocality('http://127.0.0.1:8081', 'alias')).toBe('unknown');
    expect(classifyLocality('http://127.0.0.1:8081', 'none')).toBe('unknown');
  });
  test('non-loopback endpoints are remote_service; garbage is unknown', () => {
    expect(classifyLocality('http://100.100.10.20:8081', 'exact')).toBe('remote_service');
    expect(classifyLocality('https://api.example.com/v1', 'exact')).toBe('remote_service');
    expect(classifyLocality('not a url', 'exact')).toBe('unknown');
  });
  test('endpointClass never exposes the raw URL', () => {
    expect(endpointClass('http://127.0.0.1:8081')).toBe('loopback-http');
    expect(endpointClass('http://100.100.10.20:8081')).toBe('remote-http');
  });
});

describe('sanitizePublicMessage', () => {
  test('strips absolute filesystem paths down to basenames', () => {
    const out = sanitizePublicMessage(`model ${QWEN} not found`);
    expect(out).not.toContain('/data/data');
    expect(out).not.toContain('com.termux');
    expect(out).toContain('qwen2.5-0.5b-instruct-q4_k_m.gguf');
  });
  test('redacts token-shaped values', () => {
    const out = sanitizePublicMessage('auth failed: token=sk-abc123secret');
    expect(out).not.toContain('sk-abc123secret');
  });
});

describe('resolveRuntimeIdentity — identity exists on success AND failure', () => {
  test('success: exact match + prompt → ready, localhost locality, provenance kept', () => {
    const id = resolveRuntimeIdentity(probeInput());
    expect(id.failure).toBeNull();
    expect(id.resolved.readiness).toBe('ready');
    expect(id.resolved.modelMatch).toBe('exact');
    expect(id.resolved.locality).toBe('localhost_local_inference');
    expect(id.resolved.provenance).toBe('baseline');
    expect(id.requested.model).toBe(QWEN);
    expect(id.resolved.model).toBe(QWEN);
  });

  test('endpoint unreachable: identity still exists, fails closed, sanitized', () => {
    const id = resolveRuntimeIdentity(probeInput({
      reportedModelIds: [],
      probeError: `connect ECONNREFUSED ${QWEN}`,
    }));
    expect(id.resolved.readiness).toBe('not_ready');
    expect(id.failure?.category).toBe('endpoint_unreachable');
    expect(id.failure?.publicMessage).not.toContain('/data/data');
    expect(id.resolved.model).toBeNull();
  });

  test('missing model: not_ready with model_missing and no resolved model', () => {
    const id = resolveRuntimeIdentity(probeInput({ reportedModelIds: [] }));
    expect(id.resolved.readiness).toBe('not_ready');
    expect(id.failure?.category).toBe('model_missing');
  });

  test('wrong model served: model_mismatch, locality stays unknown', () => {
    const id = resolveRuntimeIdentity(probeInput({
      reportedModelIds: ['/some/other/path/bge-small-en-v1.5-q8_0.gguf'],
    }));
    expect(id.resolved.readiness).toBe('not_ready');
    expect(id.failure?.category).toBe('model_mismatch');
    expect(id.resolved.locality).toBe('unknown');
    expect(id.failure?.publicMessage).not.toContain('/some/other/path');
  });

  test('alias-only match is UNVERIFIED, never ready, provenance unverified', () => {
    const id = resolveRuntimeIdentity(probeInput({
      reportedModelIds: ['qwen2.5-0.5b-instruct'],
    }));
    expect(id.resolved.readiness).toBe('unverified');
    expect(id.resolved.provenance).toBe('unverified');
    expect(id.failure?.category).toBe('model_mismatch');
  });

  test('missing prompt is a typed readiness failure, never an empty string', () => {
    const id = resolveRuntimeIdentity(probeInput({ promptSha256: null }));
    expect(id.resolved.readiness).toBe('not_ready');
    expect(id.failure?.category).toBe('prompt_missing');
  });
});

describe('assertRoleConsistency — fail closed on role confusion', () => {
  test('a runtime resolved for one role cannot be supplied to another', () => {
    const coherence = resolveRuntimeIdentity(probeInput({ role: 'coherence' }));
    expect(() => assertRoleConsistency(coherence, 'coherence')).not.toThrow();
    expect(() => assertRoleConsistency(coherence, 'displacement')).toThrow(/role mismatch/);
    expect(() => assertRoleConsistency(coherence, 'witness')).toThrow(/role mismatch/);
  });
});

describe('deriveRuntimePresentation — badges derive from identity', () => {
  test('verified localhost inference reads NO EGRESS / READY / BASELINE', () => {
    const p = deriveRuntimePresentation(resolveRuntimeIdentity(probeInput()));
    expect(p.egressLabel).toBe('NO EGRESS');
    expect(p.localityLabel).toBe('LOCALHOST (LOCAL INFERENCE)');
    expect(p.readinessLabel).toBe('READY');
    expect(p.provenanceBadge).toBe('BASELINE');
  });

  test('unknown locality reads EGRESS UNVERIFIED, never on-device', () => {
    const p = deriveRuntimePresentation(resolveRuntimeIdentity(probeInput({
      reportedModelIds: ['qwen2.5-0.5b-instruct'],
    })));
    expect(p.egressLabel).toBe('EGRESS UNVERIFIED');
    expect(p.localityLabel).not.toContain('ON-DEVICE');
    expect(p.readinessLabel).toBe('UNVERIFIED');
    expect(p.provenanceBadge).toBe('UNVERIFIED');
  });

  test('missing model reads NOT READY with an honest model badge', () => {
    const p = deriveRuntimePresentation(resolveRuntimeIdentity(probeInput({
      reportedModelIds: [],
    })));
    expect(p.readinessLabel).toBe('NOT READY');
    expect(p.modelBadge).toContain('(missing)');
    expect(p.provenanceBadge).toBe('UNVERIFIED');
  });

  test('a cloud-broker/remote runtime cannot claim on-device locality', () => {
    const p = deriveRuntimePresentation(resolveRuntimeIdentity(probeInput({
      endpoint: 'https://api.example.com/v1',
    })));
    expect(p.egressLabel).toBe('EGRESS: REMOTE SERVICE');
    expect(p.localityLabel).toBe('REMOTE SERVICE');
  });
});
