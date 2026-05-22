# Calibration Guide

This document describes the live EEG calibration workflow for NeuralCompose v0.4.0+.

## Overview

Before training a classifier, you need a labeled dataset of EEG windows spanning multiple gestures: rest, blink, double-blink, jaw-clench, and artifact. The calibration mode records raw EEG samples and window-level labels keyed by gesture events, producing CSV files and metadata you can replay, analyze, and use for model training.

## Device Setup

### Muse S (BLE)
1. Ensure the Muse S is charged and powered on.
2. No pairing required — BrainFlow handles discovery via SimpleBLE.
3. If multiple Muse devices are in range, export the MAC address:
   ```bash
   export NEURALCOMPOSE_MUSE_MAC="AA:BB:CC:DD:EE:FF"
   ```
   Or set the serial number:
   ```bash
   export NEURALCOMPOSE_MUSE_SERIAL_NUMBER="YOUR_SERIAL"
   ```

### Synthetic (Testing)
For development without hardware, use:
```bash
export NEURALCOMPOSE_BOARD_PROFILE=synthetic
```

## Starting a Session

### Build and Run

```bash
# With BrainFlow (requires compiled bridge)
NEURALCOMPOSE_BOARD_PROFILE=muses ./Scripts/run-calibration.sh

# With synthetic EEG
NEURALCOMPOSE_BOARD_PROFILE=synthetic ./Scripts/run-calibration.sh
```

### UI Controls

1. Click **Calibrate** to show the calibration panel
2. Click **Start Recording** to begin a session
   - A new directory is created under `~/NeuralCompose/Recordings/` with timestamp
   - EEG and label files are written in real time
3. Label gestures using keyboard or buttons (see protocol below)
4. Click **Stop Recording** to finish
   - Final summary logged; events written to `events.csv`

### Calibration Panel

- **Sticky Labels** (`[r] Rest`, `[j] Jaw Clench`, `[x] Artifact`, `[Esc] Clear`): 
  Press and hold to mark a persistent block of time. Release or press a different label to end it.

- **Event Labels** (`[b] Blink 2s`, `[d] Double Blink 3s`, `[s] Select 2s`):
  Tap to record a gesture with a fixed duration. Useful for quick, brief motions.

- **Channel Metrics** (RMS and peak µV per channel):
  Updated every window. Good data should show non-zero, stable values in the 10–100 µV range.

- **Live Stats**:
  - Windows: cumulative count of processed windows
  - Hz: sample rate (should be ~256 Hz for Muse S)
  - Dropped: overflowed windows (should be near 0 on synthetic, low on real hardware)

## Calibration Protocol

A standard 5-minute session:

1. **30 s Rest** (`[r]`): Sit still, eyes open, no blinking.
2. **20 Jaw Clenches** (`[j]` or Tap 20×): Tap once per clench (1–2 s apart).
3. **20 Blinks** (`[b]` or Tap 20×): Tap once per blink (1–2 s apart).
4. **10 Double Blinks** (`[d]` or Tap 10×): Tap once per double-blink (2–3 s apart).
5. **10 Sustained Clenches** (`[j]`): Hold for 3–5 s per clench.

**Best practices:**
- Sit upright, electrodes making good contact with skin.
- Avoid muscle tension outside the target gesture.
- Wait ~2 s between gestures for signal washout.
- Record in a quiet environment (minimize interference).

## Recording Session Output

After stopping a recording, the session directory contains:

### `eeg.csv`
Per-sample EEG, with header `t_seconds,TP9,AF7,AF8,TP10` (Muse S channels):
```csv
t_seconds,TP9,AF7,AF8,TP10
0.000000000,1.234567,-2.345678,3.456789,-1.234567
0.003906250,1.234578,-2.345689,3.456790,-1.234578
...
```
Timestamps are ISO8601 reference seconds with nanosecond precision; channel values are in µV.

### `events.csv`
Raw label events (sticky and timed), with header `session_id,t_start,t_end,label`:
```csv
session_id,t_start,t_end,label
calibration_20260522_010000_muses,0.000000,30.000000,rest
calibration_20260522_010000_muses,32.123456,33.456789,jaw_clench
...
```
Use this file to re-derive window labels with custom windowing parameters.

### `labels.csv`
Per-window ground-truth labels (derived by overlap resolution), with header `session_id,window_seq,t_start,t_end,label,profile,sample_rate`:
```csv
session_id,window_seq,t_start,t_end,label,profile,sample_rate
calibration_20260522_010000_muses,0,0.000000,2.000000,rest,muses,256.0
calibration_20260522_010000_muses,1,1.000000,3.000000,rest,muses,256.0
...
```
This is the labeled dataset for classifier training.

### `metadata.json`
Session configuration and timestamps:
```json
{
  "session_id": "calibration_20260522_010000_muses",
  "profile": "muses",
  "sample_rate": 256.0,
  "window_seconds": 2.0,
  "stride_seconds": 1.0,
  "timestamp": "2026-05-22T01:00:00Z"
}
```

## Evaluating a Session

Once you have a recorded session and a trained classifier, replay the EEG and compare predictions to ground-truth labels:

```bash
swift Scripts/evaluate-calibration.swift --session Recordings/calibration_20260522_010000_muses/
```

Output: a 6×6 confusion matrix (rest, blink, double_blink, jaw_clench, select, artifact, plus "none") with per-class accuracy.

Example output:
```
Evaluating Calibration Session
==============================
Session: calibration_20260522_010000_muses

Confusion Matrix (rows=predicted, cols=actual):
                 rest   blink   dblink   clench  select  artifact  none
         rest     42       2        0        1       0        0       5
        blink      1      38        0        0       0        0       1
       dblink      0       2       35        0       0        0       2
       clench      0       0        0       42       0        1       1
       select      0       1        0        1      38        0       0
     artifact      1       0        0        1       0       40       2
         none      1       2        0        0       2        0      48

Per-class Accuracy:
   rest: 85.7% (42/49)
  blink: 92.7% (38/41)
 dblink: 89.7% (35/39)
 clench: 95.5% (42/44)
 select: 90.5% (38/42)
artifact: 93.0% (40/43)
   none: 88.9% (48/54)

Overall Accuracy: 90.2%
```

## Interpreting Results

- **Good data**: per-class accuracy ≥85%, overall ≥88%. Channel metrics show consistent non-zero values.
- **Poor signal**: flat lines in `eeg.csv` (0.0 across a channel for >1 s), or very low RMS (<1 µV). Check electrode contact.
- **Mislabeled windows**: high off-diagonal confusion. May indicate gesture not held long enough, or overlapping time windows from multiple gestures.
- **Artifact contamination**: "none" class predicted high, or high off-diagonal for artifact row. Try re-recording in a quieter environment.

## Troubleshooting

### "Failed to start calibration: …"
Check file permissions on `~/NeuralCompose/Recordings/`. Create the directory manually if needed:
```bash
mkdir -p ~/NeuralCompose/Recordings
```

### "Dropped: X" (non-zero dropped window count)
On synthetic or idle hardware, expect ~0. On real hardware under system load, small drops (1–3 per 60 s) are acceptable. Large numbers indicate:
- **High system load**: close other apps.
- **BrainFlow polling too slow**: reduce `pollIntervalSec` in `BrainFlowService.init()`.

### Channel values are flat (all ~0.0 µV)
- **Muse S**: check electrode contact on forehead and ears. Clean with water.
- **Synthetic**: expected; use real hardware for meaningful data.

### MAC address not found / multiple devices
Export `NEURALCOMPOSE_MUSE_MAC` with the correct address (visible in macOS Bluetooth settings or the Muse app).

## Advanced: Custom Windowing

To re-derive `labels.csv` with different window sizes, edit the params in `CalibrationRecorder.beginSession()`:

```swift
await recorder.beginSession(
    to: recordingsURL,
    profile: profile,
    windowingSeconds: 3.0,  // Change from 2.0 s
    strideSeconds: 1.5      // Change from 1.0 s
)
```

Then regenerate from raw `events.csv` using the overlap resolution logic in `CalibrationRecorder.resolveLabel()`.
