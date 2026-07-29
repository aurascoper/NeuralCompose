// eegBuffer — boundedness of the raw sample buffer and channel splitting.

import { pushBounded, toChannelArrays } from '../eegBuffer';
import type { EEGSample } from '../../types/api';

const sample = (t: number): EEGSample => ({ timestamp: t, channels: [t, t + 1, t + 2, t + 3] });

describe('pushBounded', () => {
  it('never grows beyond 2x the keep size', () => {
    const keep = 8;
    let buf: EEGSample[] = [];
    for (let i = 0; i < 1000; i++) {
      buf = pushBounded(buf, sample(i), keep);
      expect(buf.length).toBeLessThanOrEqual(keep * 2);
    }
  });

  it('keeps the newest samples after trimming', () => {
    const keep = 4;
    let buf: EEGSample[] = [];
    for (let i = 0; i < 100; i++) buf = pushBounded(buf, sample(i), keep);
    const timestamps = buf.map((s) => s.timestamp);
    expect(timestamps[timestamps.length - 1]).toBe(99);
    // strictly increasing — order preserved
    expect([...timestamps].sort((a, b) => a - b)).toEqual(timestamps);
  });
});

describe('toChannelArrays', () => {
  it('splits into 4 arrays in fixed TP9, AF7, AF8, TP10 order', () => {
    const chans = toChannelArrays([sample(10), sample(20)], 100);
    expect(chans[0]).toEqual([10, 20]);
    expect(chans[1]).toEqual([11, 21]);
    expect(chans[2]).toEqual([12, 22]);
    expect(chans[3]).toEqual([13, 23]);
  });

  it('windows to the newest `keep` samples', () => {
    const samples = Array.from({ length: 50 }, (_, i) => sample(i));
    const chans = toChannelArrays(samples, 10);
    expect(chans[0]).toHaveLength(10);
    expect(chans[0][9]).toBe(49);
  });
});
