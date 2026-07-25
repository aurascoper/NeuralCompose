// sessionReducer.ts — authoritative session state machine.
// One reducer, no scattered boolean flags. Illegal transitions fail in development.
// No state permits mic-active (listening) and TTS-active (speaking) simultaneously.

import type { DialecticTuning } from './types';

export type SessionState =
  | 'idle'
  | 'requestingPermission'
  | 'ready'
  | 'listening'
  | 'transcribing'
  | 'generatingCoherence'
  | 'generatingDisplacement'
  | 'embedding'
  | 'gating'
  | 'speaking'
  | 'silent'
  | 'cueing'
  | 'cooldown'
  | 'stopped'
  | 'error';

export type SessionEvent =
  | { type: 'START_SESSION' }
  | { type: 'PERMISSION_GRANTED' }
  | { type: 'PERMISSION_DENIED'; reason: string }
  | { type: 'START_LISTENING' }
  | { type: 'STOP_LISTENING' }
  | { type: 'INJECT_TEXT' }
  | { type: 'TRANSCRIBED'; transcript: string }
  | { type: 'COHERENCE_GENERATED'; text: string }
  | { type: 'DISPLACEMENT_GENERATED'; text: string }
  | { type: 'DISPLACEMENT_FAILED'; reason: string }
  | { type: 'EMBEDDED' }
  | { type: 'GATED'; outcome: 'spoke' | 'silent' | 'synthesized' }
  | { type: 'SPEAKING_DONE' }
  | { type: 'SPEAKING_FAILED'; reason: string }
  | { type: 'SILENCE_DONE' }
  | { type: 'SILENCE_CUE' }
  | { type: 'CUE_DONE' }
  | { type: 'COOLDOWN_DONE' }
  | { type: 'STOP_SESSION' }
  | { type: 'ERROR'; reason: string }
  | { type: 'RETRY' };

/** Transition table: [currentState][eventType] -> nextState. */
const TRANSITIONS: Record<SessionState, Partial<Record<SessionEvent['type'], SessionState>>> = {
  idle: {
    START_SESSION: 'requestingPermission',
    STOP_SESSION: 'stopped',
    ERROR: 'error',
  },

  requestingPermission: {
    PERMISSION_GRANTED: 'ready',
    PERMISSION_DENIED: 'error',
    STOP_SESSION: 'stopped',
    ERROR: 'error',
  },
  ready: {
    START_LISTENING: 'listening',
    INJECT_TEXT: 'transcribing',
    STOP_SESSION: 'stopped',
    ERROR: 'error',
  },
  listening: {
    STOP_LISTENING: 'transcribing',
    STOP_SESSION: 'stopped',
    ERROR: 'error',
  },
  transcribing: {
    TRANSCRIBED: 'generatingCoherence',
    STOP_SESSION: 'stopped',
    ERROR: 'error',
  },
  generatingCoherence: {
    COHERENCE_GENERATED: 'generatingDisplacement',
    DISPLACEMENT_FAILED: 'error',
    STOP_SESSION: 'stopped',
    ERROR: 'error',
  },
  generatingDisplacement: {
    DISPLACEMENT_GENERATED: 'embedding',
    DISPLACEMENT_FAILED: 'error',
    STOP_SESSION: 'stopped',
    ERROR: 'error',
  },
  embedding: {
    EMBEDDED: 'gating',
    STOP_SESSION: 'stopped',
    ERROR: 'error',
  },
  gating: {
    GATED: 'gating', // placeholder, handled specially below
    STOP_SESSION: 'stopped',
    ERROR: 'error',
  },
  speaking: {
    SPEAKING_DONE: 'cooldown',
    SPEAKING_FAILED: 'error',
    STOP_SESSION: 'stopped',
    ERROR: 'error',
  },
  silent: {
    SILENCE_DONE: 'cooldown',
    SILENCE_CUE: 'cueing',
    STOP_SESSION: 'stopped',
    ERROR: 'error',
  },
  cueing: {
    CUE_DONE: 'cooldown',
    SPEAKING_FAILED: 'error',
    STOP_SESSION: 'stopped',
    ERROR: 'error',
  },
  cooldown: {
    COOLDOWN_DONE: 'ready',
    STOP_SESSION: 'stopped',
    ERROR: 'error',
  },
  stopped: {
    START_SESSION: 'requestingPermission',
    // Stop is idempotent: a second STOP_SESSION (unmount, background) is legal.
    STOP_SESSION: 'stopped',
  },
  error: {
    RETRY: 'ready',
    STOP_SESSION: 'stopped',
    ERROR: 'error',
  },
};

export const SessionReducer = {
  reduce(
    state: SessionState,
    event: SessionEvent,
    _tuning: DialecticTuning,
  ): [SessionState, SessionEvent] {
    // Special handling for GATED (outcome determines next state)
    if (event.type === 'GATED') {
      if (state !== 'gating') {
        throw new Error(`Illegal transition: GATED from state "${state}" (expected "gating")`);
      }
      const next: SessionState =
        event.outcome === 'silent' ? 'silent' : 'speaking';
      return [next, event];
    }

    const next = TRANSITIONS[state]?.[event.type];
    if (next === undefined) {
      throw new Error(
        `Illegal transition: ${event.type} from state "${state}"`,
      );
    }
    return [next, event];
  },
};

/** Human-readable phase label for UI display. */
export function phaseLabel(state: SessionState): string {
  switch (state) {
    case 'idle': return 'Idle';
    case 'requestingPermission': return 'Requesting permission';
    case 'ready': return 'Ready';
    case 'listening': return 'Listening';
    case 'transcribing': return 'Transcribing';
    case 'generatingCoherence': return 'Coherence voice';
    case 'generatingDisplacement': return 'Displacement voice';
    case 'embedding': return 'Embedding';
    case 'gating': return 'Weighing';
    case 'speaking': return 'Speaking';
    case 'silent': return 'Tension held';
    case 'cueing': return 'Still here';
    case 'cooldown': return 'Cooling down';
    case 'stopped': return 'Stopped';
    case 'error': return 'Error';
  }
}

/** Whether the mic is active in this state. */
export function isMicActive(state: SessionState): boolean {
  return state === 'listening';
}

/** Whether TTS is active in this state. The silence-cap cue also speaks. */
export function isTTSActive(state: SessionState): boolean {
  return state === 'speaking' || state === 'cueing';
}

/** Whether the session is active (not idle/stopped). */
export function isSessionActive(state: SessionState): boolean {
  return state !== 'idle' && state !== 'stopped';
}