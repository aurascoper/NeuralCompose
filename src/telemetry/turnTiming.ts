// turnTiming.ts — per-turn latency measurement using monotonic clocks.
// Records stage-by-stage timing for benchmark and UI display.

import type { TurnTiming } from '../dialectic/types';

/** Monotonic timestamp in milliseconds. Falls back to wall clock if the
 * runtime has no performance.now (then durations may be wrong across clock
 * adjustments — acceptable only as a last resort). */
export function now(): number {
  const perf = (globalThis as { performance?: { now(): number } }).performance;
  return perf?.now ? perf.now() : Date.now();
}

/** Creates an empty timing record. */
export function createTiming(): TurnTiming {
  return { turnTotalMs: 0, outcome: 'pending' };
}

/** Computes p50, p95, and max from an array of values. */
export function percentile(values: number[], p: number): number {
  if (values.length === 0) return 0;
  const sorted = [...values].sort((a, b) => a - b);
  const idx = Math.ceil((p / 100) * sorted.length) - 1;
  return sorted[Math.max(0, idx)];
}

/** Summary statistics for a timing field across multiple turns. */
export function timingSummary(timings: TurnTiming[], field: keyof TurnTiming): {
  p50: number; p95: number; max: number; count: number;
} {
  const values = timings
    .map((t) => t[field])
    .filter((v): v is number => typeof v === 'number' && v > 0);
  return {
    p50: percentile(values, 50),
    p95: percentile(values, 95),
    max: values.length > 0 ? Math.max(...values) : 0,
    count: values.length,
  };
}

/** Summarizes all timing fields across multiple turns. */
export function summarizeTimings(timings: TurnTiming[]): Record<string, {
  p50: number; p95: number; max: number; count: number;
}> {
  const fields: (keyof TurnTiming)[] = [
    'recordingMs', 'audioFinalizeMs', 'sttMs',
    'coherenceGenerateMs', 'displacementGenerateMs',
    'embeddingMs', 'gateMs', 'ttsStartMs', 'ttsDurationMs',
    'processingToSpeechMs', 'turnTotalMs',
  ];
  const result: Record<string, { p50: number; p95: number; max: number; count: number }> = {};
  for (const f of fields) {
    result[f] = timingSummary(timings, f);
  }
  return result;
}