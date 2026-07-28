// useEEGStream — subscribes to /api/eeg/stream and maintains a rolling buffer of samples per channel.
// Returns the latest 4-channel snapshot (one per channel) plus a flat per-channel history for the renderer.
// The MockApiClient emits ~250Hz; the real M4 server emits 256Hz. Buffer is sized via EEG_BUFFER_SAMPLES.

import { useEffect, useRef, useState } from 'react';
import { apiClient } from '../api';
import type { EEGSample } from '../types/api';
import type { EEGStreamStatus } from '../api/ApiClient';
import { EEG_BUFFER_SAMPLES } from '../config';
import { pushBounded, toChannelArrays } from './eegBuffer';

export interface EEGBuffer {
  // Per-channel rolling history, oldest → newest. Length === EEG_BUFFER_SAMPLES when full.
  channels: [number[], number[], number[], number[]];
  // Sample index of the most-recent sample. -1 if nothing received yet.
  latest: number;
  // Sample count since stream start.
  received: number;
}

const EMPTY: EEGBuffer = {
  channels: [[], [], [], []],
  latest: -1,
  received: 0,
};

export function useEEGStream(): {
  buffer: EEGBuffer;
  status: EEGStreamStatus;
  lastUpdate: number;
} {
  const [buffer, setBuffer] = useState<EEGBuffer>(EMPTY);
  const [status, setStatus] = useState<EEGStreamStatus>('connecting');
  const [lastUpdate, setLastUpdate] = useState<number>(0);
  const bufRef = useRef<EEGSample[]>([]);
  const receivedRef = useRef<number>(0);
  // Throttle re-render to ~30fps so React doesn't melt under 250Hz sample rate.
  const flushTimerRef = useRef<ReturnType<typeof setInterval> | null>(null);

  useEffect(() => {
    bufRef.current = [];
    receivedRef.current = 0;
    setBuffer(EMPTY);
    setStatus('connecting');

    const sub = apiClient.subscribeEEG(
      (sample) => {
        // Bounded: trimmed to the newest EEG_BUFFER_SAMPLES once 2x is exceeded.
        bufRef.current = pushBounded(bufRef.current, sample, EEG_BUFFER_SAMPLES);
        receivedRef.current += 1;
      },
      (s) => setStatus(s),
    );

    // ~30fps renderer flush. Drops samples if the producer is faster; that's intentional.
    flushTimerRef.current = setInterval(() => {
      const samples = bufRef.current;
      if (samples.length === 0) return;
      const channels = toChannelArrays(samples, EEG_BUFFER_SAMPLES);
      setBuffer({
        channels,
        latest: channels[0].length - 1,
        received: receivedRef.current,
      });
      setLastUpdate(Date.now());
    }, 33);

    return () => {
      sub.unsubscribe();
      if (flushTimerRef.current) clearInterval(flushTimerRef.current);
    };
  }, []);

  return { buffer, status, lastUpdate };
}
