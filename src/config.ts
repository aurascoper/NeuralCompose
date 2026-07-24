// Single point of config. Flip USE_MOCK to false and update SERVER_URL when the M4 server is ready.
// See Part 7 of the prompt for the Tailscale integration steps.

export const USE_MOCK = true;

export const SERVER_URL = 'http://100.105.8.22:8081'; // M4's Tailscale IP (placeholder)
export const EEG_WS_URL = 'ws://100.105.8.22:8081/api/eeg/stream';

// Polling intervals (ms). The M4 server emits at 256Hz over WS; HTTP endpoints are polled by the client.
export const POLL = {
  diagnostics: 1000,
  health: 1000,
  classifier: 500,
  pipelineMode: 2000,
} as const;

// EEG stream buffering: how many samples per channel to keep in the rolling buffer.
// 5 seconds @ 256Hz = 1280 samples per channel. The prompt allows downgrading to 512 (2s) if rendering stutters.
export const EEG_BUFFER_SAMPLES = 1280;

// Staleness thresholds (ms). Above these, the StaleIndicator turns orange and screens dim.
export const STALE = {
  heartbeat: 5000,        // OverviewScreen
  classifier: 5000,       // ClassifierScreen
  channelSample: 2000,    // HealthScreen
} as const;
