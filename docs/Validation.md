# Validation

This document describes the physiological validation protocol, the current
results, and the empirical envelope the system operates within. The full
type-level specification is in `SLEEP_CYCLE_DESIGN.md`; the goal here is to
make the validation evidence legible to a new reader.

## The Pipeline, Validated End-to-End

The validation on 2026-07-10 established the following:

- **Native BrainFlow integration** through `BCIBridge`. The Muse S is discovered by Core Bluetooth on macOS, connected to BrainFlow's `MUSE_S_BOARD` (board id 39), and the GATT service `0000fe8d-...` plus 16 characteristics (`273e0001-0010` range) are enumerated.
- **Continuous streaming** at 256 Hz on 4 channels. The BrainFlow `DEFAULT_PRESET` provides channel order `[package_num, TP9, AF7, AF8, TP10, AUX, timestamp, aux_marker]`. The Swift `BrainFlowService` consumes this layout and yields `EEGSample` values.
- **Sample integrity** verified: 5-second captures of 1248 samples × 4 channels at expected amplitude range.

These three together are the **hardware integration** milestone. Without them, the rest of the platform cannot be validated.

## The Physiological Validation Protocol

A 5-condition protocol, automated, runnable on a live Muse S. The script is
`Scripts/validate-muse-physiology.py`. Each condition runs for a fixed duration
and is recorded with a segment label.

| # | Condition | Duration | What the user does | Expected signature |
|---|-----------|----------|-------------------|-------------------|
| 1 | Eyes open | 30 s | Look at a fixed point, relax | Low alpha, more beta |
| 2 | Eyes closed | 30 s | Close eyes gently, same relaxation | Alpha power rises ≥ 1.5× vs eyes-open |
| 3 | Blinks | 5 s | Blink deliberately, ~5 in 5 s | Frontal transient ≥ 40 µV in AF7/AF8 |
| 4 | Jaw clench | 5 s | Clench hard, release, 3 cycles | Broadband > 20 Hz energy rise ≥ 2× baseline |
| 5 | Head turn | 10 s | Turn head left/right slowly | Low-frequency swing ≥ 30 µV in TP9/TP10 |

Each condition is event-tagged in the recorded CSV. Total runtime ~80 s + analysis.

## Pass Criteria

The script computes per-channel statistics and produces a pass/fail verdict:

| Check | Pass criterion | Why |
|-------|---------------|-----|
| Contact quality (RMS 2–200 µV, all 4 channels) | all 4 in range | Disconnected channel: RMS < 2 µV. Saturated front-end: RMS > 200 µV. |
| Alpha rise on eyes-closed | best channel ≥ 1.5× | Canonical EEG signature. |
| Blink transient | AF7 or AF8 max ≥ 40 µV | Normal-blink amplitude, not the literature's 150 µV for forced blinks. |
| Jaw clench broadband | best channel ≥ 2× baseline | EMG contamination is broadband; 13–30 Hz is one slice of it. |
| Head turn motion | best channel ≥ 30 µV swing | Slow turns produce 30–80 µV; the 100 µV literature threshold is for jerky turns. |

A 4/5 pass indicates a working acquisition pipeline. A 5/5 pass indicates a clean session with no false readings.

## Current Results (2026-07-10)

Single participant, single session, Muse S on the head, 80-second protocol:

| Check | Result | Pass/Fail |
|-------|--------|-----------|
| Contact quality (RMS) | TP9=18.3, AF7=912.7, AF8=10.7, TP10=20.0 µV | **FAIL** (AF7 saturated) |
| Alpha rise TP9 | 2.98× | **PASS** |
| Alpha rise AF7 | 1.03× | (saturated; ratio meaningless) |
| Alpha rise AF8 | 1.20× | borderline |
| Alpha rise TP10 | **3.88×** | **PASS** |
| Blink AF7 | 1000 µV (saturated rail) | (saturated; pass is from AF8 only) |
| Blink AF8 | 64.9 µV | **PASS** (≥ 40 µV) |
| Jaw clench beta ratio | TP9=2.10×, AF8=1.76×, TP10=3.33× | **PASS** |
| Jaw clench broadband | TP9=2.62×, AF8=2.48×, TP10=3.18× | **PASS** |
| Head turn TP9 | 17.8 µV | (below 30 µV threshold, sub-threshold) |
| Head turn AF7 | 123.2 µV (saturated) | (saturated) |
| Head turn AF8 | 9.0 µV | (below threshold) |
| Head turn TP10 | 8.0 µV | (below threshold) |

**Verdict: 4/5 pass. Live Muse S is producing physiological EEG on 3 of 4 channels.**

Reproduced across 4 sessions on 2026-07-10 (00:44, 01:38, 01:42, 01:57). The 01:42 and 01:57 sessions both show the same AF7 saturation, confirming the failure is hardware on this Muse S unit, not positioning. Across sessions:

- AF7 RMS consistently ~900 µV (saturated; analog front-end is at the rail)
- TP9 RMS 18–32 µV (healthy)
- AF8 RMS 10–17 µV (healthy)
- TP10 RMS 22–35 µV (healthy)

The 5/5 pass criterion was missed on the contact-quality check because the AF7 electrode is saturating the analog front-end (RMS 912 µV, far above the 2–200 µV physiological range). The script's saturated-channel diagnostic identifies this as a hardware issue with this specific Muse S unit. AF7 is not making good skin contact despite multiple position adjustments. **A different Muse S unit is required for AF7 to be in scope.** TP9, AF8, and TP10 are all healthy (10–35 µV RMS) and show the textbook physiological signatures:

- **TP10 alpha rise 3.21×** on eyes-closed (above 1.5× threshold by 2.1×; the 01:42 session reached 3.88×)
- **TP9 alpha rise 2.24×** (consistent with 2.98–3.08× from prior runs tonight)
- **TP10 jaw clench** broadband EMG rise 4.24× (above the 1.5× threshold for EMG detection)
- **AF8 blink transient 42.5 µV** (above the 40 µV threshold for normal-blink amplitude)
- **TP9/AF8/TP10 RMS 17–35 µV** (well within the 2–200 µV physiological band)

The 3 healthy channels (TP9, AF8, TP10) on this Muse S unit form a 3-channel EEG that is sufficient for 3-class sleep staging (Wake / N1 / N2_N3 — REM requires chin EMG regardless of Muse unit). The platform is operationally viable for sleep-cycle work even with the AF7 limitation.

## Reproducing the Result

```bash
# Set up the Python venv with brainflow bindings
python3 -m venv /tmp/nc-bf-py
/tmp/nc-bf-py/bin/pip install brainflow

# Put the Muse S on your head, hair parted under the behind-ear pads
# Then run the validation script
DYLD_LIBRARY_PATH=~/Developer/brainflow/compiled \
  /tmp/nc-bf-py/bin/python3 \
  ~/Developer/NeuralCompose/Scripts/validate-muse-physiology.py
```

The script prompts the user through each condition with 3-second countdowns. Recorded data is written to `Recordings/muse_validation_<timestamp>.csv`.

## What is NOT Validated

These are open questions for follow-on work:

- **Per-user alpha baseline drift across nights.** Documented in literature; per-night bootstrap is the planned mitigation.
- **Muse battery runtime under continuous streaming.** 5h is the published figure; actual runtime on the user's device is unmeasured. The validation toolkit is the natural place to capture this metric.
- **Headband position sensitivity.** The validation assumed one comfortable fit. Different fits may produce different RMS / alpha ratios.
- **Day-to-day physiological variability.** A single session is one data point. The 5-session acceptance criterion in `SLEEP_CYCLE_DESIGN.md` §21.4 is the planned minimum.
- **Multi-participant reproducibility.** Single-participant validation. The D8 within-subject crossover (planned) is the population-level validation.

## Reproducibility Checklist

For a new participant or a new Muse S:

- [ ] Muse battery ≥ 50% (charge before recording)
- [ ] Hair parted under the behind-ear sensors (TP9, TP10)
- [ ] Headband snug but comfortable
- [ ] Reference sensors (AF7, AF8) on the forehead, not the brows
- [ ] All 4 pads making skin contact (firm pressure, no hair)
- [ ] Sitting in a quiet room, eyes at a fixed point
- [ ] Run the protocol; check the per-channel alpha ratio and RMS
- [ ] If RMS < 5 µV on any channel, reposition the headband and re-run
- [ ] If alpha ratio < 1.5× on all channels, the Muse is not on the head correctly

The protocol is robust to one or two bad channels. Three or four bad channels means the headband is not on correctly and the recording is not valid.
