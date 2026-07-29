// wireFormat — WS frame decoding: batches, malformed rejection, channel order.

import { decodeEEGFrame } from '../wireFormat';

const good = { timestamp: 1.5, channels: [10, 20, 30, 40] };

describe('decodeEEGFrame', () => {
  it('decodes a single valid sample', () => {
    const out = decodeEEGFrame(JSON.stringify(good));
    expect(out).toHaveLength(1);
    expect(out[0].channels).toEqual([10, 20, 30, 40]);
  });

  it('decodes a batch array, dropping only the invalid entries', () => {
    const batch = [good, { timestamp: 2, channels: [1, 2, 3] }, { ...good, timestamp: 3 }];
    const out = decodeEEGFrame(JSON.stringify(batch));
    expect(out.map((s) => s.timestamp)).toEqual([1.5, 3]);
  });

  it('preserves fixed TP9, AF7, AF8, TP10 order — values are never reordered', () => {
    const out = decodeEEGFrame(JSON.stringify({ timestamp: 0, channels: [4, 3, 2, 1] }));
    expect(out[0].channels).toEqual([4, 3, 2, 1]);
  });

  it.each([
    ['bad JSON', 'not json{'],
    ['null', 'null'],
    ['string payload', '"hello"'],
    ['missing channels', JSON.stringify({ timestamp: 1 })],
    ['wrong channel count', JSON.stringify({ timestamp: 1, channels: [1, 2, 3, 4, 5] })],
    ['non-numeric channel', JSON.stringify({ timestamp: 1, channels: [1, 'x', 3, 4] })],
    ['NaN channel', JSON.stringify({ timestamp: 1, channels: [1, null, 3, 4] })],
    ['missing timestamp', JSON.stringify({ channels: [1, 2, 3, 4] })],
  ])('rejects %s', (_name, payload) => {
    expect(decodeEEGFrame(payload)).toEqual([]);
  });

  it('rejects non-finite values that JSON cannot even carry when injected as objects', () => {
    expect(decodeEEGFrame({ timestamp: NaN, channels: [1, 2, 3, 4] } as unknown)).toEqual([]);
    expect(decodeEEGFrame({ timestamp: 1, channels: [Infinity, 2, 3, 4] } as unknown)).toEqual([]);
  });
});
