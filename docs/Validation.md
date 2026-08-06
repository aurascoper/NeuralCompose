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
| 1–4 | Eyes open / closed, alternating **ABBA / BAAB** | 4 × 15 s | Alternate open-closed-closed-open with closed-open-open-closed across sessions | Alpha power rises ≥ 1.5× vs eyes-open **and** beats the time-index baseline |
| 5 | Blinks | 5 s | Blink deliberately, ~5 in 5 s | Frontal transient ≥ 40 µV in AF7/AF8 |
| 6 | Jaw clench | 5 s | Clench hard, release, 3 cycles | Broadband > 20 Hz energy rise ≥ 2× baseline |
| 7 | Head turn | 10 s | Turn head left/right slowly | Low-frequency swing ≥ 30 µV in TP9/TP10 |

Each condition is event-tagged in acquisition order in the recorded CSV
(`open1`/`open2` and `closed1`/`closed2`, then `blink`/`clench`/`turn`). Total
runtime is ~80 s plus analysis.

### Why the alpha contrast is counterbalanced

The protocol originally ran one 30 s eyes-open block followed by one 30 s eyes-closed
block, always in that order. Condition was therefore perfectly confounded with elapsed
time: impedance settling, electrode warming, and drowsiness onset all push
`alpha_closed / alpha_open` in the same direction as real alpha, and no analysis of that
recording can separate them.

Four blocks in either `open, closed, closed, open` or `closed, open, open, closed`
order put both conditions at the same mean position in the session (2.5), so a
linear drift subtracts out of the ratio. Alternating ABBA and BAAB reverses which
condition occupies the outer positions, flipping the curvature residual across
the session pair. The first 2 s of every block is discarded — occipital alpha
needs ~1–2 s to rise after eye closure — symmetrically across both conditions,
so the discard is not itself a thumb on the scale.

ABBA cancels a *linear* trend exactly, and electrode settling is usually curved. The
residual that curvature leaves behind is what the **time-index baseline** measures: the
identical statistic computed on the same blocks relabelled by position alone (blocks 1–2
vs 3–4), which under ABBA is orthogonal to condition. A channel passes only if the
condition ratio clears 1.5× **and** exceeds the time-index ratio. Both numbers are
reported per channel, pass or fail.

## Pass Criteria

The script computes per-channel statistics and produces a pass/fail verdict:

| Check | Pass criterion | Why |
|-------|---------------|-----|
| Contact quality (RMS 2–200 µV, all 4 channels) | all 4 in range | Disconnected channel: RMS < 2 µV. Saturated front-end: RMS > 200 µV. |
| Alpha rise on eyes-closed | best channel ≥ 1.5× **and** > its time-index ratio | Canonical EEG signature, gated so a session-long drift cannot report as alpha. |
| Blink transient | AF7 or AF8 max ≥ 40 µV | Normal-blink amplitude, not the literature's 150 µV for forced blinks. |
| Jaw clench broadband | best channel ≥ 2× baseline | EMG contamination is broadband; 13–30 Hz is one slice of it. |
| Head turn motion | best channel ≥ 30 µV swing | Slow turns produce 30–80 µV; the 100 µV literature threshold is for jerky turns. |

A 4/5 pass indicates a working acquisition pipeline. A 5/5 pass indicates a clean session with no false readings.

## Current Results (2026-08-06, BAAB replication)

The first BAAB session reversed the condition order to closed, open, open,
closed. It entered capture after three RMS checks ended with all channels inside
the recorded inclusive 2-200 uV range. Preflight status was `passed`,
`override_used` was false, and every segment contained its full sample count.
The final preflight values were TP9 95.2, AF7 137.1, AF8 60.2, and TP10 135.4
uV.

| Channel | capture RMS (uV) | capture contact | condition | time-index | shuffled condition, 10 seeds |
|---|---:|---|---:|---:|---:|
| TP9 | 82.0 | healthy | 1.18x | 1.48x | 0.81-1.54x |
| AF7 | 499.4 | saturated | 1.80x | 8.39x | 0.59-1.79x |
| AF8 | 19.9 | healthy | 1.09x | 0.93x | 0.90-1.36x |
| TP10 | 86.7 | healthy | 3.26x | 1.56x | 0.80-1.35x |

The program reported **4/5, LIKELY**: alpha, blink, jaw-clench, and head-turn
gates passed; contact failed because AF7 again degraded after preflight. The
per-block records persisted directly in the JSON localize the change:

| Block | state | TP9 | AF7 | AF8 | TP10 |
|---:|---|---:|---:|---:|---:|
| 1 | closed | 102.8 | 260.8 saturated | 21.3 | 89.3 |
| 2 | open | 77.9 | 385.7 saturated | 20.2 | 82.8 |
| 3 | open | 85.9 | 591.7 saturated | 19.7 | 90.5 |
| 4 | closed | 96.1 | 683.6 saturated | 20.0 | 89.6 |

**TP10 is now replicated under order reversal.** Its 3.26x BAAB condition ratio
beats the 1.56x time-index ratio, and all ten shuffled ratios collapse to
0.80-1.35x. The prior clean-preflight ABBA session reported 3.02x versus 0.73x,
with nine of ten shuffled ratios below 1.5x. Agreement across ABBA and BAAB
rules out the fixed condition-order explanation that invalidated the 2026-07-10
measurements. This is a replicated TP10-local spectral contrast, not yet a
two-channel posterior result.

The cross-session drift is stronger evidence than either gate alone. Time-index
reversed around 1, from 0.73x under ABBA to 1.56x under BAAB, while TP10 held at
3.02x and 3.26x. A drift-contaminated condition contrast should move with that
reversal; TP10 did not. In BAAB, the 3.26x unshuffled ratio is 2.4 times the top
of its 1.35x permutation band, with no seed reaching the 1.5x gate.

TP9 remained healthy in every BAAB block but produced 1.18x, below its 1.48x
time-index ratio and inside the 0.81-1.54x permutation range. Together with its
1.41x clean-ABBA result, TP9 is a replicated healthy-contact negative: for these
sessions, this head, and this headband position, TP10 carries the contrast and
TP9 does not. AF7's apparent 1.80x is also rejected: the channel saturated
before block 1 and its 8.39x time-index ratio dominates the condition ratio.
AF7 has saturated in all three analyzable attended captures, so it is now a
repeated hardware/positioning failure to investigate separately from protocol
quality.

### Collection implication

The protocol is no longer the blocker for collecting a **one-channel TP10**
eyes-open/eyes-closed corpus: it has produced two controlled sessions with a
replicated TP10 label and preserved negative controls. It does not unlock
spatial modeling; TP9 is a replicated negative, AF7 fails contact, and AF8 is
amplitude-confounded. The fixed classifier, features, session-level split, null
arms, stopping rule, and six-session trigger are pre-registered in
[`eyes-open-closed-step0-preregistration_v1.md`](research/eyes-open-closed-step0-preregistration_v1.md).
Collection cannot resume until its analysis implementation and synthetic tests
are committed. Two sessions remain far too thin for a classifier claim.

Evidence remains local because it contains raw EEG:

- CSV SHA-256: `606d49436d2caa3813eb718b2692d2a9ba19576f07a32b4fd012cf65ea0a3bdf`
- JSON SHA-256: `e586ef65906f5f28470f493f96ae1223b74d0af1ee24f7c1c759efdacba92eb8`
- Session metadata SHA-256: `aa65f588242635677e46efd4345793198f2bc4348fa1fedc359beb970601e6f9`
- Power state SHA-256: `c21330ba9482c6a271eab09b588fb25415679e93e6be45087ea80e6ea9123af5`

The GPD was on AC at 47% and charging, with the `powersave` governor and
`balanced` platform profile.

### Prior clean-preflight ABBA session

The next attended ABBA session entered capture only after four RMS checks ended
with all channels inside the recorded inclusive 2-200 uV range. Preflight status
was `passed`, `override_used` was false, and every segment contained its full
sample count. The final preflight values were TP9 103.7, AF7 155.8, AF8 121.5,
and TP10 68.6 uV.

| Channel | capture RMS (uV) | capture contact | condition | time-index | shuffled condition, 10 seeds |
|---|---:|---|---:|---:|---:|
| TP9 | 120.3 | healthy | 1.41x | 0.49x | 1.08-1.83x |
| AF7 | 639.7 | saturated | 0.32x | 1.01x | 0.94-1.75x |
| AF8 | 27.5 | healthy | 0.69x | 0.62x | 0.98-1.68x |
| TP10 | 83.3 | healthy | 3.02x | 0.73x | 0.87-1.85x |

The program reported **4/5, LIKELY**: alpha, blink, jaw-clench, and head-turn
gates passed; capture contact failed because AF7 degraded from a healthy 155.8
uV preflight value to 639.7 uV during the timed blocks. This distinguishes a
clean initial fit from in-session contact loss rather than treating both as the
same failure.

Post-hoc per-block RMS from the immutable CSV localizes that loss:

| Block | state | TP9 | AF7 | AF8 | TP10 |
|---:|---|---:|---:|---:|---:|
| 1 | open | 72.0 | 479.3 saturated | 32.4 | 90.8 |
| 2 | closed | 136.2 | 765.6 saturated | 28.7 | 102.2 |
| 3 | closed | 146.0 | 767.2 saturated | 23.7 | 80.7 |
| 4 | open | 154.1 | 767.3 saturated | 21.5 | 75.2 |

AF7 failed after the final preflight snapshot and before block 1, so none of its
alpha blocks is contact-valid. TP9 remained inside the healthy range in every
block, although its RMS rose monotonically.

**TP10 at 3.02x is the first defensible contrast produced by this project.** Its
condition ratio rose
from 2.05x in the prior session to 3.02x, beat its 0.73x time-index ratio, and
nine of ten shuffled ratios fell below 1.5x; the remaining shuffled ratio was
1.85x, still substantially below the unshuffled result. TP9 was now seated and
usable but reached only 1.41x, so the posterior pair did **not** agree. The new
evidence supports a repeatable TP10-local contrast, not yet a two-channel
posterior alpha result. The two session magnitudes are observations, not a
variance estimate.

Evidence remains local because it contains raw EEG:

- CSV SHA-256: `2c0aa4b8396bc413d2652ad5966c5ac9dfd737d36acfd20de6daa4dee5fba578`
- JSON SHA-256: `2a44a8865521ff29ca46504799b4009836cacb6ed231d5c2d49a166fe067092a`
- Session metadata SHA-256: `e42ee6d8880be018e2ff5d9550108d3db5d5a18c433242d1171f4229d797c882`
- Power state SHA-256: `509866d0cd1cdc5916b4c7b8438738b605f869a284b741d9b4f2b068596724f6`
- Derived block-RMS sidecar SHA-256: `0186324caedb5434800a7343aafa3d71919f31e60a3be484815872f2d12697b6`

The session metadata explicitly links its `110527` sidecar prefix to the
validator's `110528` artifact prefix; the one-second difference came from
independent timestamp calls before launch. The GPD was on AC at 37% and charging,
with the `powersave` governor and `balanced` platform profile.

### Prior attended session (contact-limited)

The first attended run of the repaired protocol completed on the GPD, based on
commit `b452015bbcddfd46cd66d8cf7575fe9ffe56d0b5` plus the uncommitted shuffle
and cue-confirmation changes. Every segment required participant acknowledgment.
All four alpha blocks contained 3,840 samples in open, closed, closed, open
order, and their cue-to-start delays were recorded separately.

**Contact preflight: not recorded (legacy).** The live RMS gate was added after
this session, so its JSON has no `contact_preflight` object. Do not interpret
absence as a pass. The post-capture RMS values below establish that contact
failed, but cannot show whether it was bad before block 1 or degraded during
the run.

| Channel | RMS (uV) | contact | condition | time-index | shuffled condition, 10 seeds |
|---|---:|---|---:|---:|---:|
| TP9 | 793.1 | saturated | 1.09x | 0.25x | 0.76-1.37x |
| AF7 | 793.3 | saturated | 1.41x | 0.59x | 0.70-2.01x |
| AF8 | 23.8 | healthy | 1.75x | 0.10x | 3.08-5.26x |
| TP10 | 77.4 | healthy | 2.05x | 0.27x | 1.10-1.55x |

The program reported **3/5, LIKELY**: alpha, blink, and jaw-clench gates passed;
contact and head-turn gates failed. That verdict is not a definitive alpha
validation.

**AF8 is the guard result.** Its 1.75x condition ratio comfortably clears the
1.5x gate and beats time-index, so every prior version of this protocol would
have accepted it as alpha. After temporal permutation the ratio rises to
3.08-5.26x. The effect is therefore a between-condition amplitude contrast,
not isolated spectral alpha. The report-only shuffle diagnostic caught a live
false positive on its first attended session.

**TP10 is the spectral candidate.** Its 2.05x condition ratio beats time-index,
while nine of ten shuffled ratios fall below 1.5x and all are substantially
below the unshuffled result. This is weaker numerically than the historical
3.88x TP10 result, but carries stronger evidence because the historical value
faced neither time-index nor shuffle control. Different sessions, contact, and
days make the two magnitudes non-comparable. The clean-preflight follow-up above
replicated TP10 with TP9 seated; TP9 did not clear the condition gate.

Contact is the binding constraint. TP9 and AF7 saturated, leaving only two
usable channels and only one usable posterior channel. The head-turn gate also
failed; poor contact is one plausible shared cause, although movement execution
is not ruled out. Treat this session as a floor on what the repaired protocol
can resolve, not as a final contrast estimate. Before the next run, clear hair
from TP9/TP10, lightly damp and reseat the contacts, and inspect signal quality
before starting the timed blocks.

Evidence remains local because it contains raw EEG:

- CSV SHA-256: `9c19cd44458180f50e4281aa7a68f02e4a4dd30de8c1ddd56b987c410199d316`
- JSON SHA-256: `c836c1a3b18c2dbf1fa6bf460867d2f02278ecae94a4e5b94a8da3c16f8194f4`
- Session metadata SHA-256: `c22222dfcea8a298e45adc40ed2e711844ddc0309b4a185a433c60147ea7852d`
- Power state SHA-256: `ed5c80f90b978cb689597070ac4cc728b68b10c65b77ab77f182f764b877082c`

The GPD was at 34% battery, discharging, with the `powersave` governor and
`balanced` platform profile. BrainFlow development logging was disabled and USB
Bluetooth autosuspend remained disabled. BrainFlow still returned
`BOARD_NOT_READY_ERROR:7` on two connection attempts before the successful run.
The BLE failure is worked around, not fixed. Failure with autosuspend disabled
refutes autosuspend as the explanation for these attempts; retry is the current
bounded workaround, and deeper BLE tracing is deferred unless failures degrade.

### Acquisition dry run

The repaired protocol completed its first live acquisition dry run on the GPD,
based on commit `b452015bbcddfd46cd66d8cf7575fe9ffe56d0b5` plus the uncommitted
shuffle diagnostics, with ABBA labels. All four alpha blocks contained the full
3,840 samples. The CSV contains 21,248 samples plus its header. The participant
did not see the eyes-open/eyes-closed instructions and kept the same eye state,
so this run **does not exercise or validate the alpha protocol**. It demonstrates
capture and analysis only; three channels were also saturated.

| Channel | RMS (uV) | condition | time-index | shuffled condition, 10 seeds |
|---|---:|---:|---:|---:|
| TP9 | 791.7 | 1.05x | 0.29x | 0.81-1.24x |
| AF7 | 793.5 | 0.87x | 0.42x | 0.66-1.38x |
| AF8 | 41.1 | 0.71x | 1.31x | 0.68-1.01x |
| TP10 | 308.4 | 0.67x | 0.85x | 0.60-0.99x |

Blink passed on AF8 at 108.4 uV. Jaw clench and head turn did not pass. The
program reported **1/5, INCONCLUSIVE**, but the alpha ratios are not physiological
results because the instructed eye-state contrast was not performed. The next
session therefore required an explicit participant ready check plus visible and
audible confirmation of every eye-state transition.

The transport result is separate and positive. With USB controller `3-5`
autosuspend disabled, `muse-ble-bridge` streamed at 256 Hz with zero drops, and
the validator subsequently completed. The successful validator run used a
temporary copy with BrainFlow development logging disabled. Logger-enabled
bridge controls also streamed successfully, so logging is **not established as
the cause** of the earlier TP9-subscribe hangs.

Evidence remains local because it contains raw EEG:

- CSV SHA-256: `525bf456d1067e60cd9877e4d8b9446ece5c384ee33dbfc3fc62f5533c914b06`
- JSON SHA-256: `279bd9d8ae3d885e81125d687f350728fe66493980fe385687e95c19c6ceb807`
- Session metadata SHA-256: `d855ff6e2906f058a7f8bd2e2d88eb8c4979022395966bd5b902fc625e40a8a9`
- Power state SHA-256: `32f5dc6286ed3a6ed7a76ba90c7c7b6e31f9ce2c4ab4b313625709d348a76874`

## Historical Results (2026-07-10)

> **On synthetic data containing zero alpha and pure drift, the old design reports 7.11×
> against a 1.5× threshold** — passing by nearly five times the margin on a signal that is
> not there. That is the regression asserted in `validate-muse-physiology.py --self-check`,
> and it is the measure of how little the old protocol constrained.
>
> **Temporal permutation puts the fixture's amplitude-only condition ratio as high as
> 1.444236× against that same 1.5× threshold.** The permutation is applied after the
> 2-second edge trim, independently within every block and channel. It destroys temporal
> spectral structure while preserving each block's samples and total variance exactly.
> The result is only 3.7% below the gate, so `condition >= 1.5×` by itself is a weak
> discriminator when eyes closing also changes broadband power. The self-check requires
> every shuffled real-alpha ratio to fail the gate and lose at least 3× of its excess over
> 1, while pure-drift time-index excess survives the same shuffle. Live sessions always
> report all ten shuffled ratios per channel, but shuffle is **not yet a live gate**; that
> promotion requires several real sessions to establish a threshold.
>
> Every figure below was collected under that protocol: the `open → closed` ordering, in
> which condition is confounded with block order. The TP9/TP10 alpha rises are large enough
> to be plausible on their face, but they are **not demonstrated** until re-collected under
> ABBA with the time-index baseline reported. Treat them as provisional; do not cite them
> as evidence the acquisition pipeline resolves alpha.
>
> **On the "0.883" figure:** the drift concern was argued for some time from a claim that
> *time-index alone classifies open vs closed at 0.883*. **That measurement has no
> preserved artifact.** It is not in any recording, script output, or log in this repo; it
> entered a working session as prose and was carried forward as established. The nearest
> values on disk — `Scripts/dream_extraction.py:335`, rho 0.8827/0.8857 — are a different
> metric on a different analysis, already annotated there as small-n artifacts. **Do not
> re-cite 0.883.** The redesign stands on the design defect, which is visible in the
> source and reproduced by the `--self-check` regression, not on that number.

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
# Then run the validation script. Alternate ABBA and BAAB across sessions.
DYLD_LIBRARY_PATH=~/Developer/brainflow/compiled \
  /tmp/nc-bf-py/bin/python3 \
  ~/Developer/NeuralCompose/Scripts/validate-muse-physiology.py --order ABBA
```

After connecting, interactive runs report a live RMS contact snapshot and require
either a clean recheck or an explicit `RUN` override before the timed protocol.
The summary JSON records every preflight check, its per-channel RMS values and
separate `healthy`, `saturated`, and `dead` classifications, the final check,
whether an override was used, and the inclusive 2–200 uV classification
thresholds. The same status, thresholds, and final per-channel classes print in
the physiological summary beside the reported ratios. The script then requires
acknowledgment of each condition before its 3-second countdown.
Recorded data is written to `Recordings/muse_validation_<timestamp>.csv` with a
matching JSON summary.

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
- [ ] If RMS is outside 2–200 µV on any channel, reposition and recheck before capture
- [ ] Interpret alpha only when condition ≥ 1.5×, beats time-index, and the report-only shuffle diagnostic supports spectral rather than amplitude contrast

The protocol is robust to one or two bad channels. Three or four bad channels means the headband is not on correctly and the recording is not valid.
