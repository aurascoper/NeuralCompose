# Recordings/

EEG recordings produced by the app when "Record" is enabled in the UI.
Format: CSV with header row `t_seconds,channel_0,channel_1,...`.

This folder is gitignored. The privacy posture of NeuralCompose is that
recorded EEG never leaves the machine; do not commit anything here.

Playback the most recent recording with:

```bash
./Scripts/run-synthetic.sh --profile playback --recording Recordings/<file>.csv
```
