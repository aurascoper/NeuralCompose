// useEEGStream — subscribes to /api/eeg/stream and maintains a rolling buffer of samples per channel.
// Returns the latest 4-channel snapshot (one per channel) plus a flat per-channel history for the renderer.
// The MockApiClient emits ~250Hz; the real M4 server emits 256Hz. Buffer is sized via EEG_BUFFER_SAMPLES.

import { useEffect, useRef, useState } from 'react';
import { apiClient } from '../api';
import type { EEGSample } from '../types/api';
import type { EEGStreamStatus } from '../api/ApiClient';
import { EEG_BUFFER_SAMPLES } from '../config';

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
        bufRef.current.push(sample);
        receivedRef.current += 1;
        // Cap memory: keep only the last 2x buffer in case flush is slow.
        if (bufRef.current.length > EEG_BUFFER_SAMPLES * 2) {
          bufRef.current = bufRef.current.slice(-EEG_BUFFER_SAMPLES);
        }
      },
      (s) => setStatus(s),
    );

    // ~30fps renderer flush. Drops samples if the producer is faster; that's intentional.
    flushTimerRef.current = setInterval(() => {
      const samples = bufRef.current;
      if (samples.length === 0) return;
      const tail = samples.slice(-EEG_BUFFER_SAMPLES);
      const channels: [number[], number[], number[], number[]] = [[], [], [], []];
      for (const s of tail) {
        channels[0].push(s.channels[0]);
        channels[1].push(s.channels[1]);
        channels[2].push(s.channels[2]);
        channels[3].push(s.channels[3]);
      }
      setBuffer({
        channels,
        latest: tail.length - 1,
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
