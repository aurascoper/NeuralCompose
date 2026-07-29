// config resolution — mock/live selection, endpoint handling, no silent fallback.

import { parseUseMock, deriveWsUrl, resolveClientMode } from '../config';

describe('parseUseMock', () => {
  it('defaults to mock when unset or empty', () => {
    expect(parseUseMock(undefined)).toBe(true);
    expect(parseUseMock('')).toBe(true);
  });

  it('selects live only on an explicit false-y string', () => {
    expect(parseUseMock('false')).toBe(false);
    expect(parseUseMock('FALSE')).toBe(false);
    expect(parseUseMock('0')).toBe(false);
    expect(parseUseMock('no')).toBe(false);
  });

  it('treats affirmative and junk values as mock (safe default)', () => {
    expect(parseUseMock('true')).toBe(true);
    expect(parseUseMock('1')).toBe(true);
    expect(parseUseMock('banana')).toBe(true);
  });
});

describe('deriveWsUrl', () => {
  it('maps http(s) to ws(s) and appends the stream path', () => {
    expect(deriveWsUrl('http://host:8081')).toBe('ws://host:8081/api/eeg/stream');
    expect(deriveWsUrl('https://host:8081')).toBe('wss://host:8081/api/eeg/stream');
  });

  it('returns empty for non-http inputs', () => {
    expect(deriveWsUrl('')).toBe('');
    expect(deriveWsUrl('host:8081')).toBe('');
  });
});

describe('resolveClientMode', () => {
  it('mock mode needs no endpoints and reports no error', () => {
    const c = resolveClientMode(undefined, undefined, undefined);
    expect(c.mode).toBe('mock');
    expect(c.configError).toBeNull();
  });

  it('live mode with a valid server URL resolves endpoints', () => {
    const c = resolveClientMode('false', 'http://mac.example:8081/', undefined);
    expect(c.mode).toBe('live');
    expect(c.serverUrl).toBe('http://mac.example:8081'); // trailing slash trimmed
    expect(c.eegWsUrl).toBe('ws://mac.example:8081/api/eeg/stream');
    expect(c.configError).toBeNull();
  });

  it('an explicit WS URL wins over derivation', () => {
    const c = resolveClientMode('false', 'https://mac.example', 'wss://mac.example/custom');
    expect(c.eegWsUrl).toBe('wss://mac.example/custom');
  });

  it('live mode with an empty server URL is a visible config error, NOT mock', () => {
    const c = resolveClientMode('false', '', '');
    expect(c.mode).toBe('live'); // never silently substitutes mock
    expect(c.configError).toMatch(/EXPO_PUBLIC_SERVER_URL is not set/);
  });

  it('live mode with a malformed server URL is a visible config error, NOT mock', () => {
    const c = resolveClientMode('false', 'not-a-url', undefined);
    expect(c.mode).toBe('live');
    expect(c.configError).toMatch(/invalid EXPO_PUBLIC_SERVER_URL/);
  });
});
