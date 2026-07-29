// wireFormat — validation for EEG frames arriving on the WebSocket.
// The server sends one JSON sample per message (~256Hz) today; a frame may also
// be a JSON array of samples (batch), which decodes to the same output.
// Channel order is fixed TP9, AF7, AF8, TP10 — samples are rejected, never
// reordered. Malformed frames yield [] and are dropped upstream.

import type { EEGSample } from '../types/api';

export const EEG_CHANNEL_COUNT = 4;

function isValidSample(v: unknown): v is EEGSample {
  if (typeof v !== 'object' || v === null) return false;
  const s = v as { timestamp?: unknown; channels?: unknown };
  if (typeof s.timestamp !== 'number' || !Number.isFinite(s.timestamp)) return false;
  if (!Array.isArray(s.channels) || s.channels.length !== EEG_CHANNEL_COUNT) return false;
  return s.channels.every((c) => typeof c === 'number' && Number.isFinite(c));
}

/**
 * Decode one WebSocket message into zero or more valid samples.
 * - single sample object → [sample]
 * - batch array → the valid samples, invalid entries dropped
 * - anything else (bad JSON, wrong shape, NaN/Infinity, wrong channel count) → []
 */
export function decodeEEGFrame(data: unknown): EEGSample[] {
  let parsed: unknown;
  try {
    parsed = typeof data === 'string' ? JSON.parse(data) : data;
  } catch {
    return [];
  }
  if (Array.isArray(parsed)) {
    return parsed.filter(isValidSample);
  }
  return isValidSample(parsed) ? [parsed] : [];
}
