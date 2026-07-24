// API contract types — single source of truth for both MockApiClient and LiveApiClient.
// Mirrors the M4 server's HTTP/WebSocket schema (see NeuralCompose/docs/NeuralCompose-android-client-prompt.md Part 2).

export type TransportKind =
  | 'OSC (Mind Monitor)'
  | 'BrainFlow (BLE)'
  | 'Playback'
  | 'Synthetic'
  | 'Unknown';

export interface StreamDiagnostics {
  transport: TransportKind;
  sampleRate: number;             // Hz
  packetsReceived: number;
  packetsDropped: number;
  packetLossEstimate: number | null;
  packetJitterMillis: number;
  lastInterArrivalMillis: number;
  lastHeartbeat: string;          // ISO 8601
  boundPort: number;
  localInterfaceName: string;     // e.g. "utun3" for Tailscale
}

export type ChannelStatus = 'healthy' | 'saturated' | 'dead' | 'unknown';

export interface ChannelHealthState {
  channel: 'TP9' | 'AF7' | 'AF8' | 'TP10';
  status: ChannelStatus;
  rms: number;                    // µV
  samples: number;
  timestamp: number;              // seconds since stream start
  lastSampleWallClock: number;    // unix seconds
}

export type IntentLabel = 'rest' | 'jawClench' | 'singleBlink' | 'doubleBlink' | 'select';

export interface IntentDistribution {
  rest: number;
  jawClench: number;
  singleBlink: number;
  doubleBlink: number;
  select: number;
}

export interface IntentPrediction {
  intent: IntentLabel;
  confidence: number;             // 0..1
  distribution: IntentDistribution;
  windowSequence: number;
  endTimestamp: number;           // seconds since stream start
}

export type PipelineSource = 'oscRemote' | 'brainFlow' | 'playback' | 'synthetic';
export type ClassifierKind = 'coreML' | 'mock';
export type PredictorKind = 'mlx' | 'stub';

export interface PipelineMode {
  source: PipelineSource;
  sourceProfile: string;          // human-readable
  classifier: ClassifierKind;
  predictor: PredictorKind;
  transportDetail: string;        // e.g. "UDP 5000 · utun3"
  isFullyLive: boolean;           // true only when source=oscRemote/brainFlow + classifier=coreML + predictor=mlx
  substitutionSummary: string;
}

export interface EEGSample {
  timestamp: number;              // seconds since stream start
  channels: [number, number, number, number]; // TP9, AF7, AF8, TP10 (µV)
}
