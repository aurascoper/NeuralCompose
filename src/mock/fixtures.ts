// Mock fixtures — exact JSON samples from the prompt's API contract (Part 2).
// These match what the M4 server will return so the MockApiClient and LiveApiClient are interchangeable.

import type {
  ChannelHealthState,
  IntentPrediction,
  PipelineMode,
  StreamDiagnostics,
} from '../types/api';

export const MOCK_DIAGNOSTICS: StreamDiagnostics = {
  transport: 'OSC (Mind Monitor)',
  sampleRate: 256.0,
  packetsReceived: 15432,
  packetsDropped: 3,
  packetLossEstimate: null,
  packetJitterMillis: 2.4,
  lastInterArrivalMillis: 3.9,
  lastHeartbeat: '2026-07-23T18:30:00Z',
  boundPort: 5000,
  localInterfaceName: 'utun3',
};

export const MOCK_HEALTH: ChannelHealthState[] = [
  { channel: 'TP9',  status: 'healthy',   rms: 162.5, samples: 77966, timestamp: 305.2, lastSampleWallClock: 1783738346.0 },
  { channel: 'AF7',  status: 'healthy',   rms: 176.6, samples: 77966, timestamp: 305.2, lastSampleWallClock: 1783738346.0 },
  { channel: 'AF8',  status: 'saturated', rms: 971.0, samples: 77966, timestamp: 305.2, lastSampleWallClock: 1783738346.0 },
  { channel: 'TP10', status: 'healthy',   rms: 146.4, samples: 77966, timestamp: 305.2, lastSampleWallClock: 1783738346.0 },
];

export const MOCK_CLASSIFIER: IntentPrediction = {
  intent: 'rest',
  confidence: 0.89,
  distribution: {
    rest: 0.89,
    jawClench: 0.04,
    singleBlink: 0.03,
    doubleBlink: 0.02,
    select: 0.02,
  },
  windowSequence: 15432,
  endTimestamp: 305.2,
};

export const MOCK_PIPELINE_MODE: PipelineMode = {
  source: 'oscRemote',
  sourceProfile: 'OSC Remote (network)',
  classifier: 'coreML',
  predictor: 'mlx',
  transportDetail: 'UDP 5000 · utun3',
  isFullyLive: false,
  substitutionSummary: 'EEG: OSC Remote (network) (UDP 5000 · utun3)',
};
