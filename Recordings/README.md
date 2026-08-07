# Recordings/

EEG recordings produced by the app when "Record" is enabled in the UI.
Format: CSV with header row `t_seconds,channel_0,channel_1,...`.

This folder is gitignored. The privacy posture of NeuralCompose is that
recorded EEG never leaves the machine; do not commit anything here.

Playback the most recent recording with:

```bash
./Scripts/run-synthetic.sh --profile playback --recording Recordings/<file>.csv
```

## Session events

A recording can be summarised into structured, replayable observations:

```bash
python3 Scripts/extract_session_events.py Recordings/<session>
```

This writes `<session>/session-events.jsonl` — one `nc-eeg-session-event-v0`
record per observation. Events carry the **SHA-256 of `eeg.csv` plus a sample
range**, never signal, so the log is meaningless without the recording it points
into and the privacy posture above is unchanged: the log stays here, and here is
gitignored.

They are **signal observations only**. No sleep stage, no intervention outcome —
`Scripts/session_event_contract.py` rejects a record that asserts either. See
[`docs/architecture/session-events.md`](../docs/architecture/session-events.md).
