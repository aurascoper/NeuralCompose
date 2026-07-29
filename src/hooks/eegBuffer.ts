// eegBuffer — pure helpers behind useEEGStream, extracted so boundedness and
// channel-order behavior are unit-testable without a React renderer.

import type { EEGSample } from '../types/api';

/**
 * Append a sample to the raw buffer, keeping memory bounded: once the buffer
 * exceeds 2×keep (flush running behind), it is trimmed to the newest `keep`.
 */
export function pushBounded(buf: EEGSample[], sample: EEGSample, keep: number): EEGSample[] {
  buf.push(sample);
  if (buf.length > keep * 2) {
    return buf.slice(-keep);
  }
  return buf;
}

/**
 * Split the newest `keep` samples into per-channel arrays in the fixed
 * TP9, AF7, AF8, TP10 order. Never reorders channels.
 */
export function toChannelArrays(
  samples: EEGSample[],
  keep: number,
): [number[], number[], number[], number[]] {
  const tail = samples.length > keep ? samples.slice(-keep) : samples;
  const channels: [number[], number[], number[], number[]] = [[], [], [], []];
  for (const s of tail) {
    channels[0].push(s.channels[0]);
    channels[1].push(s.channels[1]);
    channels[2].push(s.channels[2]);
    channels[3].push(s.channels[3]);
  }
  return channels;
}
