// Single point of config. Endpoints and mode come from EXPO_PUBLIC_* env vars
// (statically referenced — Expo inlines them at bundle time; they are PUBLIC,
// never put secrets here). Copy .env.example to .env.local and edit to point at
// your own server. No private addresses belong in this file.
//
// Mode rules (see resolveClientMode):
// - EXPO_PUBLIC_USE_MOCK unset/empty/"true" → mock mode, labeled MOCK in the UI.
// - EXPO_PUBLIC_USE_MOCK="false" → live mode. A live-server failure stays
//   visible; there is NO automatic fallback to mock data.
// - Live mode with an empty/malformed EXPO_PUBLIC_SERVER_URL is a visible
//   configuration error ("no endpoint"), not a silent downgrade to mock.

export type ClientMode = 'mock' | 'live';

export interface ResolvedClientConfig {
  mode: ClientMode;
  serverUrl: string; // '' when unset
  eegWsUrl: string;  // '' when unresolvable
  /** Non-null when live mode is selected but endpoints are unusable. */
  configError: string | null;
}

/** "false"/"0"/"no" (any case) select live mode; everything else stays mock. */
export function parseUseMock(raw: string | undefined): boolean {
  if (raw === undefined) return true;
  const v = raw.trim().toLowerCase();
  if (v === 'false' || v === '0' || v === 'no') return false;
  return true;
}

function normalizeUrl(raw: string | undefined): string {
  const v = (raw ?? '').trim();
  return v.replace(/\/+$/, '');
}

/** Derive ws(s):// stream URL from the HTTP server URL when not given explicitly. */
export function deriveWsUrl(serverUrl: string): string {
  if (!/^https?:\/\//.test(serverUrl)) return '';
  return serverUrl.replace(/^http/, 'ws') + '/api/eeg/stream';
}

export function resolveClientMode(
  useMockRaw: string | undefined,
  serverRaw: string | undefined,
  wsRaw: string | undefined,
): ResolvedClientConfig {
  const mock = parseUseMock(useMockRaw);
  const serverUrl = normalizeUrl(serverRaw);
  const eegWsUrl = normalizeUrl(wsRaw) || deriveWsUrl(serverUrl);
  if (mock) {
    return { mode: 'mock', serverUrl, eegWsUrl, configError: null };
  }
  if (!/^https?:\/\//.test(serverUrl)) {
    return {
      mode: 'live',
      serverUrl,
      eegWsUrl,
      configError: serverUrl
        ? `invalid EXPO_PUBLIC_SERVER_URL: ${serverUrl}`
        : 'EXPO_PUBLIC_SERVER_URL is not set',
    };
  }
  return { mode: 'live', serverUrl, eegWsUrl, configError: null };
}

// EXPO_PUBLIC_* vars must be referenced statically (no dynamic indexing) so the
// Expo bundler can inline them.
export const CLIENT_CONFIG: ResolvedClientConfig = resolveClientMode(
  process.env.EXPO_PUBLIC_USE_MOCK,
  process.env.EXPO_PUBLIC_SERVER_URL,
  process.env.EXPO_PUBLIC_EEG_WS_URL,
);

export const USE_MOCK = CLIENT_CONFIG.mode === 'mock';
export const SERVER_URL = CLIENT_CONFIG.serverUrl;
export const EEG_WS_URL = CLIENT_CONFIG.eegWsUrl;
export const CONFIG_ERROR = CLIENT_CONFIG.configError;

// Polling intervals (ms). The M4 server emits at 256Hz over WS; HTTP endpoints are polled by the client.
export const POLL = {
  diagnostics: 1000,
  health: 1000,
  classifier: 500,
  pipelineMode: 2000,
} as const;

// EEG stream buffering: how many samples per channel to keep in the rolling buffer.
// 5 seconds @ 256Hz = 1280 samples per channel. Downgrade to 512 (2s) if rendering stutters.
export const EEG_BUFFER_SAMPLES = 1280;

// Local LLM endpoint — llama-server (Qwen 0.5B Q4_K_M). On the Pixel this runs
// in Termux on the device loopback. On iOS there is no loopback server, so
// synthesis fails visibly ("synthesis unavailable") unless an override points
// at a reachable host.
export const LLM_URL = process.env.EXPO_PUBLIC_LLM_URL || 'http://127.0.0.1:8081';

// Staleness thresholds (ms). Above these, the StaleIndicator turns orange and screens dim.
export const STALE = {
  heartbeat: 5000,        // OverviewScreen
  classifier: 5000,       // ClassifierScreen
  channelSample: 2000,    // HealthScreen
} as const;
