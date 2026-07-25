// useDialecticSession.ts — the session hook that ties everything together.
// Orchestration only: state machine transitions, epoch cancellation, timers.
// The actual turn runs through src/session/turnPipeline.ts — the single
// execution path shared by UI, tests, and benchmarks.
//
// Fail-closed: startSession probes prompts + the configured Qwen model before
// READY. Embedding down → MOCK gates (labeled, synthesis disabled). STT down →
// text injection only. No provider is ever substituted.

import { useCallback, useEffect, useRef, useState } from 'react';
import {
  SessionReducer, phaseLabel, isMicActive, isTTSActive, isSessionActive,
  type SessionState, type SessionEvent,
} from '../dialectic/sessionReducer';
import { createEngineState, type EngineState } from '../dialectic/engine';
import { getProfile, DEFAULT_TUNING } from '../dialectic/profiles';
import type { ProfileID, TurnTiming, ServiceHealth, ModelManifest } from '../dialectic/types';
import { PROMPT_PROFILE } from '../dialectic/prompts';
import { runLiveTurn } from '../session/turnPipeline';
import { checkSessionReadiness } from '../session/readiness';
import { generateCandidate } from '../services/GenerationClient';
import { embedBatch, mockEmbed } from '../services/EmbeddingClient';
import { transcribeAudio } from '../services/TranscriptionClient';
import { speak, stopSpeaking } from '../services/SpeechOutput';
import { checkAllServices, checkTTS } from '../services/ServiceHealth';
import { getManifest, provenanceBadge } from '../services/modelManifest';
import { now } from '../telemetry/turnTiming';
import { assertRoleConsistency, type RuntimeIdentity } from '../runtime/identity';

/** Per-role identities resolved at readiness; witness is never resolved on Android. */
export type SessionIdentities = {
  coherence: RuntimeIdentity;
  displacement: RuntimeIdentity;
  witness: null;
};

/** Static local cue after the consecutive-silence cap. Not a model output. */
const SILENCE_CUE_TEXT = 'Still here.';

export interface DialecticSessionState {
  phase: SessionState;
  phaseLabel: string;
  profile: ProfileID;
  transcript: string;
  lastSpoken: string | null;
  lastOutcome: 'spoke' | 'silent' | 'synthesized' | null;
  lastTension: number;
  lastMargin: number;
  lastTiming: TurnTiming | null;
  serviceHealth: ServiceHealth[];
  manifest: ModelManifest | null;
  provenanceLabel: string;
  promptProfileLabel: string;
  isMicActive: boolean;
  isTTSActive: boolean;
  isSessionActive: boolean;
  error: string | null;
  sttAvailable: boolean;
  /** Requested-vs-resolved runtime identities; set on success AND failure. */
  identities: SessionIdentities | null;
  // Developer diagnostics
  lastCandidates: Array<{ roleID: string; text: string; potential: number }> | null;
  lastDraw: number | null;
  embeddingMode: 'live' | 'mock';
  consecutiveSilence: number;
  turns: number;
}

export interface DialecticSessionActions {
  startSession: () => Promise<void>;
  stopSession: () => Promise<void>;
  startListening: () => void;
  /** Process a finished push-to-talk recording through local STT. */
  processRecording: (audioUri: string) => Promise<void>;
  /** Inject text directly (STT bypass; labeled — never microphone acceptance). */
  injectText: (text: string) => Promise<void>;
  setProfile: (id: ProfileID) => void;
  retry: () => void;
  refreshHealth: () => Promise<void>;
}

export function useDialecticSession(): {
  state: DialecticSessionState;
  actions: DialecticSessionActions;
} {
  const [phase, setPhase] = useState<SessionState>('idle');
  const [profile, setProfileState] = useState<ProfileID>('focused');
  const [transcript, setTranscript] = useState('');
  const [lastSpoken, setLastSpoken] = useState<string | null>(null);
  const [lastOutcome, setLastOutcome] = useState<'spoke' | 'silent' | 'synthesized' | null>(null);
  const [lastTension, setLastTension] = useState(0);
  const [lastMargin, setLastMargin] = useState(0);
  const [lastTiming, setLastTiming] = useState<TurnTiming | null>(null);
  const [serviceHealth, setServiceHealth] = useState<ServiceHealth[]>([]);
  const [error, setError] = useState<string | null>(null);
  const [sttAvailable, setSttAvailable] = useState(false);
  const [lastCandidates, setLastCandidates] = useState<Array<{ roleID: string; text: string; potential: number }> | null>(null);
  const [lastDraw, setLastDraw] = useState<number | null>(null);
  const [embeddingMode, setEmbeddingMode] = useState<'live' | 'mock'>('mock');
  const [consecutiveSilence, setConsecutiveSilence] = useState(0);
  const [turns, setTurns] = useState(0);
  const [identities, setIdentities] = useState<SessionIdentities | null>(null);

  // Refs for cancellation and async safety
  const epochRef = useRef(0);
  const abortRef = useRef<AbortController | null>(null);
  const engineStateRef = useRef<EngineState | null>(null);
  const manifestRef = useRef<ModelManifest | null>(null);
  const embeddingModeRef = useRef<'live' | 'mock'>('mock');
  const identitiesRef = useRef<SessionIdentities | null>(null);

  const transition = useCallback((event: SessionEvent) => {
    setPhase(prev => {
      const [next] = SessionReducer.reduce(prev, event, DEFAULT_TUNING);
      return next;
    });
  }, []);

  const refreshHealth = useCallback(async () => {
    const services = await checkAllServices();
    services.push(checkTTS());
    setServiceHealth(services);
  }, []);

  // Initialize manifest on mount; cancel everything on unmount (idempotent).
  useEffect(() => {
    manifestRef.current = getManifest();
    return () => {
      epochRef.current++;
      abortRef.current?.abort();
      void stopSpeaking();
    };
  }, []);

  const startSession = useCallback(async () => {
    const epoch = ++epochRef.current;
    abortRef.current = new AbortController();
    engineStateRef.current = createEngineState(getProfile(profile).tuning);
    setError(null);
    setConsecutiveSilence(0);
    setTurns(0);
    transition({ type: 'START_SESSION' });

    // Fail-closed readiness: prompts + positive Qwen model probe gate READY.
    const readiness = await checkSessionReadiness();
    if (epoch !== epochRef.current) return;
    setEmbeddingMode(readiness.embeddingMode);
    embeddingModeRef.current = readiness.embeddingMode;
    setSttAvailable(readiness.sttAvailable);
    // Identities exist on success AND failure — the UI derives every badge
    // (provider, model, locality, egress, readiness) from them.
    identitiesRef.current = readiness.identities;
    setIdentities(readiness.identities);
    if (!readiness.ok) {
      const reason = readiness.reasons.join('; ');
      transition({ type: 'ERROR', reason });
      setError(`Not ready: ${reason}`);
      return;
    }
    transition({ type: 'PERMISSION_GRANTED' });
    void refreshHealth();
  }, [profile, transition, refreshHealth]);

  const stopSession = useCallback(async () => {
    epochRef.current++;
    abortRef.current?.abort();
    await stopSpeaking();
    // STOP_SESSION is legal from every state (idempotent from 'stopped').
    transition({ type: 'STOP_SESSION' });
  }, [transition]);

  const startListening = useCallback(() => {
    transition({ type: 'START_LISTENING' });
  }, [transition]);

  /** Shared turn runner. Assumes phase is 'transcribing'. */
  const runPipelineTurn = useCallback(async (text: string) => {
    const epoch = epochRef.current;
    const tuning = getProfile(profile).tuning;
    if (!engineStateRef.current) {
      engineStateRef.current = createEngineState(tuning);
    }
    const engineState = engineStateRef.current;
    const signal = abortRef.current?.signal;
    setTranscript(text);

    try {
      const report = await runLiveTurn(
        {
          generate: async (roleID, heard, standingTension) => {
            // Role-consistency guard (A2): each generation must go through the
            // identity resolved for its own role; anything else fails the turn.
            const role = roleID === 'coherence-seeking' ? 'coherence' as const : 'displacement' as const;
            const identity = identitiesRef.current?.[role];
            if (!identity) {
              return { reason: `no resolved runtime identity for role "${role}"`, latencyMs: 0 };
            }
            if (identity.resolved.readiness !== 'ready') {
              return {
                reason: identity.failure?.publicMessage ?? `runtime for role "${role}" is not ready`,
                latencyMs: 0,
              };
            }
            try {
              assertRoleConsistency(identity, role);
            } catch (err: any) {
              return { reason: String(err?.message ?? err), latencyMs: 0 };
            }
            const r = await generateCandidate(roleID, heard, standingTension, manifestRef.current, { signal, timeoutMs: 30000 });
            return 'reason' in r ? { reason: r.reason, latencyMs: r.latencyMs } : r;
          },
          embedLive: async (texts) => {
            const r = await embedBatch(texts, { signal, timeoutMs: 20000 });
            return 'reason' in r ? { reason: r.reason, latencyMs: r.latencyMs } : r;
          },
          embedMock: (texts) => mockEmbed(texts),
          speak: (text_, prosody) => speak(text_, prosody, { signal }),
          dispatch: (event) => {
            if (epoch === epochRef.current) transition(event);
          },
          isCurrent: () => epoch === epochRef.current,
          rng: () => Math.random(),
          nowMs: now,
        },
        {
          transcript: text,
          embeddingMode: embeddingModeRef.current,
          tuning,
          engineState,
          silenceCueText: SILENCE_CUE_TEXT,
        },
      );
      if (epoch !== epochRef.current) return;

      setLastTiming(report.timing);
      if (report.draw !== undefined) setLastDraw(report.draw);
      if (report.turnOutput) {
        const out = report.turnOutput;
        setLastTension(out.result.tension);
        setLastMargin(out.result.margin);
        setLastCandidates(out.scored.map((s) => ({
          roleID: s.candidate.roleID,
          text: s.candidate.text,
          potential: s.potential,
        })));
        setConsecutiveSilence(engineState.consecutiveSilence);
        setTurns(engineState.turnIndex);
        if (out.spokenText) {
          setLastSpoken(out.spokenText);
          setLastOutcome(out.outcome.kind === 'synthesized' ? 'synthesized' : 'spoke');
        } else {
          setLastOutcome('silent');
        }
      }

      if (report.status === 'error') {
        setError(report.errorReason ?? 'turn failed');
        return;
      }
      if (report.status === 'stale') return;

      // Real cooldown: hold the profile's inter-turn pause, then re-arm.
      // The timer always fires; the epoch guard makes a late firing harmless.
      await new Promise<void>((resolve) => setTimeout(resolve, tuning.interTurnCooldownMs));
      if (epoch !== epochRef.current) return;
      transition({ type: 'COOLDOWN_DONE' });
    } catch (err: any) {
      if (epoch !== epochRef.current) return;
      transition({ type: 'ERROR', reason: String(err?.message ?? err) });
      setError(String(err?.message ?? err));
    }
  }, [profile, transition]);

  const injectText = useCallback(async (text: string) => {
    transition({ type: 'INJECT_TEXT' });
    await runPipelineTurn(text);
  }, [transition, runPipelineTurn]);

  const processRecording = useCallback(async (audioUri: string) => {
    const epoch = epochRef.current;
    transition({ type: 'STOP_LISTENING' });
    const stt = await transcribeAudio(audioUri, { signal: abortRef.current?.signal, timeoutMs: 30000 });
    if (epoch !== epochRef.current) return;
    if ('reason' in stt) {
      transition({ type: 'ERROR', reason: `STT: ${stt.reason}` });
      setError(`Transcription failed: ${stt.reason}`);
      return;
    }
    await runPipelineTurn(stt.text);
  }, [transition, runPipelineTurn]);

  const setProfile = useCallback((id: ProfileID) => {
    setProfileState(id);
    engineStateRef.current = createEngineState(getProfile(id).tuning);
  }, []);

  const retry = useCallback(() => {
    setError(null);
    transition({ type: 'RETRY' });
  }, [transition]);

  const manifest = manifestRef.current;
  const provenanceLabel = manifest ? provenanceBadge(manifest) : 'UNVERIFIED';

  return {
    state: {
      phase,
      phaseLabel: phaseLabel(phase),
      profile,
      transcript,
      lastSpoken,
      lastOutcome,
      lastTension,
      lastMargin,
      lastTiming,
      serviceHealth,
      manifest,
      provenanceLabel,
      promptProfileLabel: `${PROMPT_PROFILE.id}/${PROMPT_PROFILE.version}#${PROMPT_PROFILE.hash}`,
      isMicActive: isMicActive(phase),
      isTTSActive: isTTSActive(phase),
      isSessionActive: isSessionActive(phase),
      error,
      sttAvailable,
      identities,
      lastCandidates,
      lastDraw,
      embeddingMode,
      consecutiveSilence,
      turns,
    },
    actions: {
      startSession,
      stopSession,
      startListening,
      processRecording,
      injectText,
      setProfile,
      retry,
      refreshHealth,
    },
  };
}
