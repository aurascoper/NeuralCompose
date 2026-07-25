// sessionReducerAdditions.test.ts — Fable 5 repairs:
// text-injection path, cueing state, idempotent stop.

import { SessionReducer, isMicActive, isTTSActive, type SessionState } from '../sessionReducer';
import { DEFAULT_TUNING } from '../profiles';

describe('SessionReducer additions', () => {
  test('ready -> transcribing on INJECT_TEXT (text injection is a legal path)', () => {
    const [state] = SessionReducer.reduce('ready', { type: 'INJECT_TEXT' }, DEFAULT_TUNING);
    expect(state).toBe('transcribing');
  });

  test('INJECT_TEXT is illegal outside ready', () => {
    for (const s of ['idle', 'listening', 'speaking', 'cooldown'] as SessionState[]) {
      expect(() => SessionReducer.reduce(s, { type: 'INJECT_TEXT' }, DEFAULT_TUNING)).toThrow();
    }
  });

  test('silent -> cueing -> cooldown for the silence-cap cue', () => {
    const [cueing] = SessionReducer.reduce('silent', { type: 'SILENCE_CUE' }, DEFAULT_TUNING);
    expect(cueing).toBe('cueing');
    const [cooldown] = SessionReducer.reduce('cueing', { type: 'CUE_DONE' }, DEFAULT_TUNING);
    expect(cooldown).toBe('cooldown');
  });

  test('cueing counts as TTS-active and never mic-active', () => {
    expect(isTTSActive('cueing')).toBe(true);
    expect(isMicActive('cueing')).toBe(false);
  });

  test('cueing TTS failure goes to error', () => {
    const [state] = SessionReducer.reduce('cueing', { type: 'SPEAKING_FAILED', reason: 'x' }, DEFAULT_TUNING);
    expect(state).toBe('error');
  });

  test('STOP_SESSION is idempotent from stopped', () => {
    const [state] = SessionReducer.reduce('stopped', { type: 'STOP_SESSION' }, DEFAULT_TUNING);
    expect(state).toBe('stopped');
  });

  test('mic cannot open from cueing', () => {
    expect(() => SessionReducer.reduce('cueing', { type: 'START_LISTENING' }, DEFAULT_TUNING)).toThrow();
  });
});
