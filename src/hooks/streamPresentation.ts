// streamPresentation — truthful presentation of a live stream's health.
// Socket state alone is not health: an open socket with no recent samples is
// STALE, not OPEN (found by the Gate 4 open-but-silent fixture). Pure so the
// pill/banner logic is unit-testable without a renderer.

import type { EEGStreamStatus } from '../api/ApiClient';

export type StreamTone = 'ok' | 'stale' | 'connecting' | 'down';

export interface StreamPresentation {
  label: string;
  tone: StreamTone;
  /** Non-null when a warning banner should be shown alongside the pill. */
  banner: string | null;
}

/**
 * @param status   underlying WebSocket status
 * @param ageMs    ms since the newest sample was received; Infinity if none yet
 * @param staleAfterMs  silence threshold before an open stream is presented stale
 */
export function presentStream(
  status: EEGStreamStatus,
  ageMs: number,
  staleAfterMs: number,
): StreamPresentation {
  if (status === 'connecting') {
    return { label: 'CONNECTING', tone: 'connecting', banner: null };
  }
  if (status === 'closed' || status === 'error') {
    return {
      label: status.toUpperCase(),
      tone: 'down',
      banner: 'Stream disconnected — showing last cached data',
    };
  }
  // status === 'open'
  if (!Number.isFinite(ageMs)) {
    return { label: 'OPEN · NO DATA', tone: 'stale', banner: null };
  }
  if (ageMs > staleAfterMs) {
    const s = Math.floor(ageMs / 1000);
    return {
      label: `STALE ${s}s`,
      tone: 'stale',
      banner: `Stream silent — no samples for ${s}s (socket still open)`,
    };
  }
  return { label: 'OPEN', tone: 'ok', banner: null };
}
