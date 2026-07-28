// streamPresentation — open-but-silent streams must present STALE, not OPEN.
// Regression for the Gate 4 finding: socket state alone is not stream health.

import { presentStream } from '../streamPresentation';

const THRESHOLD = 2000;

describe('presentStream', () => {
  it('presents a fresh open stream as OPEN/ok with no banner', () => {
    const v = presentStream('open', 500, THRESHOLD);
    expect(v).toEqual({ label: 'OPEN', tone: 'ok', banner: null });
  });

  it('treats the threshold itself as still fresh, one past it as stale', () => {
    expect(presentStream('open', THRESHOLD, THRESHOLD).tone).toBe('ok');
    expect(presentStream('open', THRESHOLD + 1, THRESHOLD).tone).toBe('stale');
  });

  it('presents an open-but-silent stream as STALE with an explanatory banner', () => {
    const v = presentStream('open', 7000, THRESHOLD);
    expect(v.label).toBe('STALE 7s');
    expect(v.tone).toBe('stale');
    expect(v.banner).toMatch(/no samples for 7s/);
    expect(v.banner).toMatch(/socket still open/);
  });

  it('presents open-with-no-samples-ever as stale NO DATA, not healthy', () => {
    const v = presentStream('open', Infinity, THRESHOLD);
    expect(v.label).toBe('OPEN · NO DATA');
    expect(v.tone).toBe('stale');
  });

  it('presents connecting as its own tone without a disconnect banner', () => {
    const v = presentStream('connecting', Infinity, THRESHOLD);
    expect(v).toEqual({ label: 'CONNECTING', tone: 'connecting', banner: null });
  });

  it.each(['closed', 'error'] as const)('presents %s as down with the cached-data banner', (s) => {
    const v = presentStream(s, 1000, THRESHOLD);
    expect(v.label).toBe(s.toUpperCase());
    expect(v.tone).toBe('down');
    expect(v.banner).toMatch(/Stream disconnected/);
  });

  it('never reports ok for a non-open socket regardless of age', () => {
    expect(presentStream('closed', 0, THRESHOLD).tone).toBe('down');
    expect(presentStream('connecting', 0, THRESHOLD).tone).toBe('connecting');
  });
});
