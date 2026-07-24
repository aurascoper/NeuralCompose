// ApiClient interface — the single contract both MockApiClient and LiveApiClient implement.
// Hooks (useDiagnostics, useHealth, etc.) talk to whichever client is wired in src/config.ts.

import type {
  ChannelHealthState,
  IntentPrediction,
  PipelineMode,
  StreamDiagnostics,
  EEGSample,
} from '../types/api';

export type EEGStreamHandler = (sample: EEGSample) => void;
export type EEGStreamStatus = 'connecting' | 'open' | 'closed' | 'error';

export interface EEGStreamSubscription {
  unsubscribe: () => void;
}

export interface ApiClient {
  getDiagnostics(): Promise<StreamDiagnostics>;
  getHealth(): Promise<ChannelHealthState[]>;
  getClassifier(): Promise<IntentPrediction>;
  getPipelineMode(): Promise<PipelineMode>;

  // WebSocket. Subscribe returns an unsubscribe handle.
  // onSample is called for every EEG sample received (~256Hz).
  // onStatus is called when the underlying socket changes state.
  subscribeEEG(onSample: EEGStreamHandler, onStatus: (s: EEGStreamStatus) => void): EEGStreamSubscription;
}
