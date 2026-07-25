// SpeechOutput.ts — expo-speech adapter with completion/cancellation.
// Uses expo-speech for spoken output. Mic and speaker must alternate strictly.

import * as Speech from 'expo-speech';
import type { SpeechProsody } from '../dialectic/types';

export interface SpeechOptions {
  signal?: AbortSignal;
}

/**
 * Speaks text with prosody shaping. Returns when speech completes or is cancelled.
 * Checks the abort signal before and during speech.
 */
export async function speak(
  text: string,
  prosody: SpeechProsody,
  opts: SpeechOptions = {},
): Promise<{ cancelled: boolean; error: boolean; durationMs: number }> {
  if (opts.signal?.aborted) return { cancelled: true, error: false, durationMs: 0 };

  const start = Date.now();

  return new Promise((resolve) => {
    let resolved = false;

    const finish = (cancelled: boolean, error = false) => {
      if (resolved) return;
      resolved = true;
      resolve({ cancelled, error, durationMs: Date.now() - start });
    };

    // Listen for abort
    opts.signal?.addEventListener('abort', () => {
      Speech.stop();
      finish(true);
    }, { once: true });

    const speakOpts: Speech.SpeechOptions = {
      rate: prosody.rate ?? 1.0,
      pitch: prosody.pitch ?? 1.0,
      volume: prosody.volume ?? 1.0,
      language: 'en-US',
      onDone: () => finish(false),
      onStopped: () => finish(true),
      onError: () => finish(false, true),
    };

    // Pre-delay if specified
    if (prosody.preDelayMs && prosody.preDelayMs > 0) {
      setTimeout(() => {
        if (opts.signal?.aborted) {
          finish(true);
          return;
        }
        Speech.speak(text, speakOpts);
      }, prosody.preDelayMs);
    } else {
      Speech.speak(text, speakOpts);
    }
  });
}

/** Stops any in-progress speech. Safe to call when idle. */
export async function stopSpeaking(): Promise<void> {
  await Speech.stop();
}

/** Gets available Android voice identifiers. */
export async function getVoices(): Promise<string[]> {
  try {
    const voices = await Speech.getAvailableVoicesAsync();
    return voices.map((v) => v.identifier).filter(Boolean) as string[];
  } catch {
    return [];
  }
}