// LiveApiClient — real HTTP + WebSocket against the M4 server over Tailscale.
// Used when USE_MOCK = false in src/config.ts. The M4 server is not yet built (per the prompt),
// so this is a working reference implementation that the user can switch on later.

import type {
  ApiClient,
  EEGStreamHandler,
  EEGStreamStatus,
  EEGStreamSubscription,
} from './ApiClient';
import type {
  ChannelHealthState,
  IntentPrediction,
  PipelineMode,
  StreamDiagnostics,
  EEGSample,
} from '../types/api';
import { EEG_WS_URL, SERVER_URL } from '../config';

async function fetchJson<T>(path: string, init?: RequestInit): Promise<T> {
  const res = await fetch(`${SERVER_URL}${path}`, {
    ...init,
    headers: { 'Accept': 'application/json', ...(init?.headers ?? {}) },
  });
  if (!res.ok) {
    throw new Error(`${path} → HTTP ${res.status}`);
  }
  return (await res.json()) as T;
}

export class LiveApiClient implements ApiClient {
  async getDiagnostics(): Promise<StreamDiagnostics> {
    return fetchJson<StreamDiagnostics>('/api/diagnostics');
  }
  async getHealth(): Promise<ChannelHealthState[]> {
    return fetchJson<ChannelHealthState[]>('/api/health');
  }
  async getClassifier(): Promise<IntentPrediction> {
    return fetchJson<IntentPrediction>('/api/classifier');
  }
  async getPipelineMode(): Promise<PipelineMode> {
    return fetchJson<PipelineMode>('/api/pipeline-mode');
  }

  subscribeEEG(
    onSample: EEGStreamHandler,
    onStatus: (s: EEGStreamStatus) => void,
  ): EEGStreamSubscription {
    let ws: WebSocket | null = null;
    let closed = false;
    let attempt = 0;
    let reconnectTimer: ReturnType<typeof setTimeout> | null = null;

    const connect = () => {
      if (closed) return;
      onStatus('connecting');
      try {
        ws = new WebSocket(EEG_WS_URL);
      } catch (err) {
        onStatus('error');
        scheduleReconnect();
        return;
      }
      ws.onopen = () => {
        attempt = 0;
        onStatus('open');
      };
      ws.onmessage = (ev) => {
        try {
          const sample = JSON.parse(String(ev.data)) as EEGSample;
          onSample(sample);
        } catch {
          // Drop malformed frames.
        }
      };
      ws.onerror = () => onStatus('error');
      ws.onclose = () => {
        onStatus('closed');
        scheduleReconnect();
      };
    };

    const scheduleReconnect = () => {
      if (closed) return;
      attempt += 1;
      if (attempt > 3) {
        // Banner should display "Stream disconnected" via onStatus('error').
        onStatus('error');
        return;
      }
      const backoff = Math.min(30000, 500 * 2 ** attempt);
      reconnectTimer = setTimeout(connect, backoff);
    };

    connect();

    return {
      unsubscribe: () => {
        closed = true;
        if (reconnectTimer) clearTimeout(reconnectTimer);
        if (ws) {
          ws.onopen = ws.onmessage = ws.onerror = ws.onclose = null;
          ws.close();
        }
      },
    };
  }
}
