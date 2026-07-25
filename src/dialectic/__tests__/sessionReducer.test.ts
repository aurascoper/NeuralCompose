// sessionReducer.test.ts — the authoritative session state machine.
// Tests that illegal transitions fail and no state permits mic+TTS overlap.

import { SessionReducer, type SessionState, type SessionEvent } from '../sessionReducer';
import { DEFAULT_TUNING } from '../profiles';

describe('SessionReducer', () => {
  test('idle -> requestingPermission on START_SESSION', () => {
    const [state] = SessionReducer.reduce('idle', { type: 'START_SESSION' }, DEFAULT_TUNING);
    expect(state).toBe('requestingPermission');
  });

  test('requestingPermission -> ready on PERMISSION_GRANTED', () => {
    const [state] = SessionReducer.reduce('requestingPermission', { type: 'PERMISSION_GRANTED' }, DEFAULT_TUNING);
    expect(state).toBe('ready');
  });

  test('ready -> listening on START_LISTENING', () => {
    const [state] = SessionReducer.reduce('ready', { type: 'START_LISTENING' }, DEFAULT_TUNING);
    expect(state).toBe('listening');
  });

  test('listening -> transcribing on STOP_LISTENING', () => {
    const [state] = SessionReducer.reduce('listening', { type: 'STOP_LISTENING' }, DEFAULT_TUNING);
    expect(state).toBe('transcribing');
  });

  test('transcribing -> generatingCoherence on TRANSCRIBED', () => {
    const [state] = SessionReducer.reduce('transcribing', { type: 'TRANSCRIBED', transcript: 'test' }, DEFAULT_TUNING);
    expect(state).toBe('generatingCoherence');
  });

  test('generatingCoherence -> generatingDisplacement on COHERENCE_GENERATED', () => {
    const [state] = SessionReducer.reduce('generatingCoherence', { type: 'COHERENCE_GENERATED', text: 'coh' }, DEFAULT_TUNING);
    expect(state).toBe('generatingDisplacement');
  });

  test('generatingDisplacement -> embedding on DISPLACEMENT_GENERATED', () => {
    const [state] = SessionReducer.reduce('generatingDisplacement', { type: 'DISPLACEMENT_GENERATED', text: 'disp' }, DEFAULT_TUNING);
    expect(state).toBe('embedding');
  });

  test('embedding -> gating on EMBEDDED', () => {
    const [state] = SessionReducer.reduce('embedding', { type: 'EMBEDDED' }, DEFAULT_TUNING);
    expect(state).toBe('gating');
  });

  test('gating -> speaking on GATED with spoke outcome', () => {
    const [state] = SessionReducer.reduce('gating', { type: 'GATED', outcome: 'spoke' }, DEFAULT_TUNING);
    expect(state).toBe('speaking');
  });

  test('gating -> silent on GATED with silent outcome', () => {
    const [state] = SessionReducer.reduce('gating', { type: 'GATED', outcome: 'silent' }, DEFAULT_TUNING);
    expect(state).toBe('silent');
  });

  test('speaking -> cooldown on SPEAKING_DONE', () => {
    const [state] = SessionReducer.reduce('speaking', { type: 'SPEAKING_DONE' }, DEFAULT_TUNING);
    expect(state).toBe('cooldown');
  });

  test('silent -> cooldown on SILENCE_DONE', () => {
    const [state] = SessionReducer.reduce('silent', { type: 'SILENCE_DONE' }, DEFAULT_TUNING);
    expect(state).toBe('cooldown');
  });

  test('cooldown -> ready on COOLDOWN_DONE', () => {
    const [state] = SessionReducer.reduce('cooldown', { type: 'COOLDOWN_DONE' }, DEFAULT_TUNING);
    expect(state).toBe('ready');
  });

  test('STOP_SESSION from any active state goes to stopped', () => {
    const activeStates: SessionState[] = [
      'requestingPermission', 'ready', 'listening', 'transcribing',
      'generatingCoherence', 'generatingDisplacement', 'embedding',
      'gating', 'speaking', 'silent', 'cooldown',
    ];
    for (const s of activeStates) {
      const [state] = SessionReducer.reduce(s, { type: 'STOP_SESSION' }, DEFAULT_TUNING);
      expect(state).toBe('stopped');
    }
  });

  test('error from any state on ERROR', () => {
    const states: SessionState[] = ['idle', 'ready', 'listening', 'transcribing'];
    for (const s of states) {
      const [state] = SessionReducer.reduce(s, { type: 'ERROR', reason: 'test' }, DEFAULT_TUNING);
      expect(state).toBe('error');
    }
  });

  test('error -> ready on RETRY', () => {
    const [state] = SessionReducer.reduce('error', { type: 'RETRY' }, DEFAULT_TUNING);
    expect(state).toBe('ready');
  });

  test('illegal transition throws in development', () => {
    expect(() => {
      SessionReducer.reduce('idle', { type: 'START_LISTENING' }, DEFAULT_TUNING);
    }).toThrow();
  });

  test('no state transition permits mic-active and TTS-active simultaneously', () => {
    // The states 'listening' (mic) and 'speaking' (TTS) must never be
    // reachable from each other directly.
    // Verify: from listening, no event leads to speaking
    const events: SessionEvent[] = [
      { type: 'STOP_LISTENING' },
      { type: 'STOP_SESSION' },
      { type: 'ERROR', reason: 'test' },
    ];
    for (const e of events) {
      const [state] = SessionReducer.reduce('listening', e, DEFAULT_TUNING);
      expect(state).not.toBe('speaking');
    }
    // From speaking, no event leads to listening
    const speakingEvents: SessionEvent[] = [
      { type: 'SPEAKING_DONE' },
      { type: 'STOP_SESSION' },
      { type: 'ERROR', reason: 'test' },
    ];
    for (const e of speakingEvents) {
      const [state] = SessionReducer.reduce('speaking', e, DEFAULT_TUNING);
      expect(state).not.toBe('listening');
    }
  });
});