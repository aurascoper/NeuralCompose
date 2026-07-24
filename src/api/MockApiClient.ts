// MockApiClient — local in-memory simulation of the M4 server.
// Returns fixtures with realistic jitter, incrementing counters, and a synthetic EEG stream.
// Drop-in replacement for LiveApiClient; hooks and screens don't know the difference.

import type {
  ApiClient,
  EEGStreamHandler,
  EEGStreamStatus,
  EEGStreamSubscription,
} from './ApiClient';
import type {
  ChannelHealthState,
  EEGSample,
  IntentDistribution,
  IntentLabel,
  IntentPrediction,
  PipelineMode,
  StreamDiagnostics,
} from '../types/api';
import {
  MOCK_CLASSIFIER,
  MOCK_DIAGNOSTICS,
  MOCK_HEALTH,
  MOCK_PIPELINE_MODE,
} from '../mock/fixtures';

// Per-channel nominal RMS (µV). AF8 in the fixture is saturated; the others stay near baseline.
const CHANNEL_BASE_RMS = [162.5, 176.6, 971.0, 146.4] as const;
const CHANNEL_NAMES = ['TP9', 'AF7', 'AF8', 'TP10'] as const;

// Simulate ~256Hz EEG with 4ms ticks. Drive via setInterval at 4ms.
const EEG_TICK_MS = 4;
const EEG_HZ = 1000 / EEG_TICK_MS; // 250Hz — close enough; UI labels it 256Hz like the real M4

// Intent cycle: shift the dominant intent every ~8 seconds so the UI has something to show.
const INTENT_CYCLE: IntentLabel[] = ['rest', 'rest', 'rest', 'singleBlink', 'rest', 'rest', 'rest', 'doubleBlink', 'rest', 'rest', 'jawClench', 'select', 'rest'];
const INTENT_CYCLE_PERIOD_MS = 8000;

function jitter(amp: number): number {
  // Box-Muller-ish uniform normal; cheap and good enough for visual purposes.
  return (Math.random() + Math.random() + Math.random() - 1.5) * amp;
}

function makeSample(streamStart: number, simTime: number): EEGSample {
  const t = simTime; // seconds since stream start
  // Mix a slow 10Hz alpha-ish wave with random noise; saturate AF8 with a clipped DC offset.
  const channels: [number, number, number, number] = [
    CHANNEL_BASE_RMS[0] * 0.1 * Math.sin(2 * Math.PI * 10 * t) + jitter(20),
    CHANNEL_BASE_RMS[1] * 0.1 * Math.sin(2 * Math.PI * 10 * t + 0.5) + jitter(20),
    // AF8 saturated: high DC + small ripple, occasionally clipped near ±1000µV.
    800 + 100 * Math.sin(2 * Math.PI * 0.5 * t) + jitter(50),
    CHANNEL_BASE_RMS[3] * 0.1 * Math.sin(2 * Math.PI * 10 * t + 1.0) + jitter(20),
  ];
  return { timestamp: t, channels };
}

function makeClassifier(_now: number, simTime: number): IntentPrediction {
  const idx = Math.floor((simTime * 1000) / INTENT_CYCLE_PERIOD_MS) % INTENT_CYCLE.length;
  const dominant = INTENT_CYCLE[idx];
  const confidence = 0.7 + 0.25 * Math.random();
  // Build the distribution immutably so TypeScript can verify every IntentLabel key is set.
  const others = (['rest', 'jawClench', 'singleBlink', 'doubleBlink', 'select'] as IntentLabel[]).filter(l => l !== dominant);
  const remaining = 1 - confidence;
  const othersShare = others.map((_, i) =>
    i === others.length - 1 ? remaining : (remaining / others.length) * (0.5 + Math.random())
  );
  let distribution: IntentDistribution = {
    rest: 0,
    jawClench: 0,
    singleBlink: 0,
    doubleBlink: 0,
    select: 0,
  };
  others.forEach((label, i) => {
    distribution[label] = othersShare[i];
  });
  distribution[dominant] = confidence;
  // Fix floating-point drift so the sum is exactly 1.0.
  const sum = (Object.values(distribution) as number[]).reduce((a, b) => a + b, 0);
  const drift = 1 - sum;
  distribution[dominant] += drift;
  return {
    intent: dominant,
    confidence,
    distribution,
    windowSequence: Math.floor(simTime * EEG_HZ),
    endTimestamp: simTime,
  };
}

export class MockApiClient implements ApiClient {
  private streamStart: number = Date.now();
  private packetsReceived: number = MOCK_DIAGNOSTICS.packetsReceived;
  private samples: number = 77966;
  private classifierCount: number = MOCK_CLASSIFIER.windowSequence;
  private currentIntent: IntentLabel = 'rest';
  private subscribers: Set<{ onSample: EEGStreamHandler; onStatus: (s: EEGStreamStatus) => void }> = new Set();
  private eegTimer: ReturnType<typeof setInterval> | null = null;
  private statusTimer: ReturnType<typeof setInterval> | null = null;
  private connectedAt: number | null = null;

  constructor() {
    // Stagger the "connection open" event so subscribers can attach first.
    this.statusTimer = setInterval(() => this.broadcastStatus('open'), 100);
  }

  private broadcastStatus(s: EEGStreamStatus) {
    this.subscribers.forEach(sub => sub.onStatus(s));
  }

  private get simTime(): number {
    return (Date.now() - this.streamStart) / 1000;
  }

  async getDiagnostics(): Promise<StreamDiagnostics> {
    await new Promise(r => setTimeout(r, 20 + Math.random() * 60));
    // Tick packetsReceived by ~256 per second of wall time since last call.
    this.packetsReceived += 256 + Math.floor(Math.random() * 4);
    return {
      ...MOCK_DIAGNOSTICS,
      packetsReceived: this.packetsReceived,
      packetJitterMillis: 1.5 + Math.random() * 2,
      lastInterArrivalMillis: 3.5 + Math.random() * 1.5,
      lastHeartbeat: new Date().toISOString(),
    };
  }

  async getHealth(): Promise<ChannelHealthState[]> {
    await new Promise(r => setTimeout(r, 20 + Math.random() * 40));
    this.samples += Math.floor(EEG_HZ * 1.05); // ~1s of samples per poll
    return MOCK_HEALTH.map((c, i) => ({
      ...c,
      rms: c.channel === 'AF8' ? 950 + Math.random() * 50 : c.rms + jitter(8),
      samples: this.samples,
      timestamp: this.simTime,
      lastSampleWallClock: Date.now() / 1000,
    })) as ChannelHealthState[];
  }

  async getClassifier(): Promise<IntentPrediction> {
    await new Promise(r => setTimeout(r, 10 + Math.random() * 30));
    this.classifierCount += Math.floor(EEG_HZ * 0.5);
    const pred = makeClassifier(Date.now(), this.simTime);
    this.currentIntent = pred.intent;
    return { ...pred, windowSequence: this.classifierCount };
  }

  async getPipelineMode(): Promise<PipelineMode> {
    await new Promise(r => setTimeout(r, 20 + Math.random() * 50));
    return MOCK_PIPELINE_MODE;
  }

  subscribeEEG(
    onSample: EEGStreamHandler,
    onStatus: (s: EEGStreamStatus) => void,
  ): EEGStreamSubscription {
    const sub = { onSample, onStatus };
    this.subscribers.add(sub);
    onStatus('connecting');

    if (!this.eegTimer) {
      this.connectedAt = Date.now();
      this.eegTimer = setInterval(() => {
        const sample = makeSample(this.streamStart, this.simTime);
        this.subscribers.forEach(s => s.onSample(sample));
      }, EEG_TICK_MS);
      // Open after one tick so the UI sees 'connecting' → 'open' transition.
      setTimeout(() => this.broadcastStatus('open'), 50);
    }

    return {
      unsubscribe: () => {
        this.subscribers.delete(sub);
        if (this.subscribers.size === 0 && this.eegTimer) {
          clearInterval(this.eegTimer);
          this.eegTimer = null;
          this.broadcastStatus('closed');
        }
      },
    };
  }
}

// Singleton — screens import this directly.
export const mockApiClient = new MockApiClient();
