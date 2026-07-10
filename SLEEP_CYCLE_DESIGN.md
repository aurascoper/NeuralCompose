# Sleep-Cycle Design — NeuralCompose

> **Status**: v1, draft. Implementation has not started.
> **Author**: Designed 2026-07-10 from `~/NeuralCompose_dream_prompt.md` (v2, 420 lines, last edited 2026-07-09).
> **Grounding**: Live Muse acquisition confirmed end-to-end via BrainFlow on 2026-07-10. During initial validation, the recorded participant exhibited approximately a 3× increase in alpha power during eyes-closed compared to eyes-open on TP9, AF7, and TP10. This validates the acquisition pipeline but should not be treated as a normative threshold — it is a calibration observation, not a general claim. See `Scripts/validate-muse-physiology.py` and `Recordings/muse_validation_20260710-004400.csv`.
> **Hardware target**: Muse S (MUSE_S_BOARD = 39), confirmed with user 2026-07-10. The Muse 2 (board 38) and Muse S Athena (board 67) are forward-compat paths. The validation on 2026-07-10 was on a Muse S and the runtime design uses Muse S defaults. The repo's HARDWARE_SETUP.md documents the older BLED112 dongle transport (now deprecated by BrainFlow 5.22+) but the active path is native BLE through macOS Core Bluetooth on the built-in BCM_4388C2.
> **Predecessor**: Imagined-speech calibration (`ImaginedSpeechProtocol.swift`, `TrackBRecorder.swift`) is the precedent for the protocol-actor pattern used in `DreamSessionController` and `SleepSessionFSM`.

This document specifies the type-level design for a new sleep-cycle mode in NeuralCompose. It does not contain runnable code. The output of this document is a set of types, protocols, and contracts that make implementation mechanical. Every heuristic carries a confidence rating (High / Medium / Low). Every claim about scientific status is marked established / plausible / unproven.

---

## §1 Assumptions and Design Decisions

These are the assumptions that materially affect implementation. If any of them is wrong, the corresponding sections need revision.

1. **Hardware is Muse S.** Confirmed with user 2026-07-10. BrainFlow board id 39. Muse 2 (board 38) and Muse S Athena (board 67) are forward-compat paths. The validation on 2026-07-10 was on a Muse S; the runtime design uses Muse S defaults. The repo's HARDWARE_SETUP.md documents the older BLED112 dongle transport (now deprecated by BrainFlow 5.22+) but the active path is native BLE through macOS Core Bluetooth.
2. **Battery life is conservatively assumed at 4-5 hours of continuous streaming unless empirically characterized for the specific device and firmware.** A 7-8 hour overnight session is out of scope until per-device runtime is measured. The Muse's USB port can charge while worn, but introduces cable noise; the design budgets for a 4-5 hour session window with optional in-session charge.
3. **The Muse S cannot measure chin EMG or EOG.** REM detection without atonia is unreliable. The output stage set is `{WAKE, N1, N2_N3, UNCERTAIN_REM}` — 4 classes, not 5.
4. **M4 SoC die temperature is userland-unreadable.** `AppleSMCKeysEndpoint` is kernel-gated. We have CPU-time, per-process RSS, and load-average as observable signals. The 85°C throttle threshold in the prompt is enforced as a *soft* signal (combined CPU pressure + sustained perf-state reduction). A `sudo powermetrics` capture is recommended at first overnight session; the design does not require it.
5. **The MacBook will be plugged in overnight.** macOS power-saver throttles sustained workloads; without AC, the 8-hour LLM analysis at the end of the session is at risk. The session-start wizard should require AC confirmation.
6. **The Core ML sleep stage classifier runs on the ANE.** M-series ANE has a working memory budget of ~200 MB and prefers fixed input shapes. A 30s × 4ch × 128-bin spectrogram at 4 bytes is 1 MB; model itself is targeted at <30 MB. Within budget.
7. **MLX primer generation is one-shot and pre-sleep.** Latency target: ≤30 s. MLX dream analysis is post-sleep, also one-shot. Neither is real-time.
8. **The audio path uses `AVAudioEngine` (Foundation + AVFoundation only).** No third-party audio dependencies. The 60 dB SPL cap is enforced through (a) a calibration step at session start that records the user's "0 dB" reference volume, and (b) a per-cue volume bound relative to that reference. macOS does not expose SPL; this is a software-relative cap, not an absolute SPL measurement.
9. **Per-user alpha baseline calibration is essential.** Alpha dropout is a *relative* measure. The system establishes a 30-second eyes-closed alpha baseline during the pre-sleep primer or a separate calibration session. The baseline is used for the per-epoch dropout ratio.
10. **No new third-party SwiftPM dependencies.** The existing isolation (MLX in BCILLM only) is preserved. New code goes into BCICore (pure-Swift types, protocols, FSMs) and BCIClassifier (Core ML). New audio goes into a new `BCIAudio` target depending on Foundation + AVFoundation only.
11. **No telemetry, no cloud.** All session data, EEG, dream reports, and analysis stay on-device. Deletion is a single action.
12. **The Muse S GATT stream provides 4 EEG channels at 256 Hz and no aux/PPG/IMU in the default preset.** This matches the BrainFlow `DEFAULT_PRESET` layout used in `BrainFlowService.swift`. Channel order in the buffer: `[package_num, TP9, AF7, AF8, TP10, AUX, timestamp, aux_marker]`. The sleep pipeline consumes channels 1-4 (TP9, AF7, AF8, TP10).
13. **The Muse S's 12-bit ADC means dynamic range is ~±1000 µV with ~0.49 µV resolution per LSB.** Adequate for EEG band analysis up to ~50 Hz. Detail above 50 Hz is degraded; the sleep stage classifier should bandpass to 0.5-30 Hz before feature extraction.
14. **Existing protocols are NOT modified.** New protocols are added in parallel: `SleepStaging` (alongside `IntentClassifying`), `DreamAnalysisPredicting` (alongside `NextWordPredicting`).
15. **Implementation order** is now: build verified (DONE) → live Muse verified (DONE) → physiological validation (DONE) → **Sleep Validation Toolkit (§21) — must be stable before any classifier work** → 30s epoch windowing → sleep feature extraction → Wake/N1/N2+ classifier → session FSM → LLM primer + analysis → experimental features. The toolkit is the gate; the classifier and downstream components depend on it being a reliable debugging surface.
16. **TMR cue delivery is the *least* validated element of the pipeline.** The literature on TMR for declarative memory is robust; for creative insight it is plausible but unproven. The design includes a sham condition in D8 precisely to control for placebo.
17. **Domain adaptation from PSG to Muse S is considered the largest expected source of model error.** Sleep-EDFx and SHHS use central and occipital bipolar derivations; the Muse S uses 4 unipolar frontal channels. The geometry, reference scheme, and frequency response differ. Any model trained on public PSG data must be re-validated on per-user Muse S data before claims about Muse S sleep staging are made. This is the single most likely place the system will underperform published accuracy numbers, and it should be treated as the primary unknown until per-user validation is done.

---

## §2 Architecture Overview

NeuralCompose is extended with a parallel "sleep-cycle" mode that shares the existing EEG acquisition stack (`EEGStreaming`) and audio subsystem, but introduces new protocols, actors, and a finite-state machine that orchestrates a multi-hour overnight session. The new components are *additive*: existing communication-mode types are not modified. A high-level pipeline:

```
                    ┌──────────────────────────────────────────────────────┐
                    │                NeuralComposeApp                       │
                    │  (SwiftUI: session wizard, recall UI, analysis view)  │
                    └─────┬──────────────────────────┬──────────────────────┘
                          │                          │
                          │ starts                   │ subscribes
                          ▼                          ▼
                ┌──────────────────┐        ┌─────────────────────────┐
                │ DreamSession    │        │  DreamSessionController │
                │ Config          │        │  (actor)                │
                └────────┬─────────┘        │  publishes Snapshot via │
                         │                  │  BoundedAsyncChannel    │
                         ▼                  └─────┬────────┬──────────┘
                ┌──────────────────┐              │        │
                │ AudioFeedback    │◀─────────────┘        │
                │ Protocol         │                       │
                │ (BCIAudio, new)  │                       ▼
                └──────────────────┘              ┌──────────────────┐
                                                  │ SleepSessionFSM  │
                                                  │ (struct, value)  │
                                                  └─────┬────────┬───┘
                                                        │        │
                                  ┌─────────────────────┘        │
                                  ▼                              ▼
                          ┌─────────────┐               ┌──────────────────┐
                          │ SleepStage  │               │ DreamAnalysis    │
                          │ Smoother    │               │ Predicting       │
                          │ (actor)     │               │ (LLM, via BCILLM)│
                          └─────┬───────┘               └──────────────────┘
                                │
                                ▼
                          ┌──────────────────┐
                          │ SleepStaging     │
                          │ (Core ML + mock) │
                          └─────┬────────────┘
                                │
                                ▼
                          ┌──────────────────┐
                          │ EEGWindowing     │  (extended: 30s epochs, 5s stride)
                          │ (actor)          │
                          └─────┬────────────┘
                                │
                                ▼
                          ┌──────────────────┐
                          │ EEGStreaming     │  (existing, reused as-is)
                          │  → BrainFlow     │
                          │  → Muse S        │
                          └──────────────────┘
```

**Module boundaries**:

- `BCICore` gains: `SleepStage`, `SleepStagePrediction`, `SleepFeatures`, `SleepWindowingConfig`, `SleepStaging` protocol, `SleepStageSmoother` actor, `SleepSessionPhase` enum, `SleepSessionFSM` struct, `DreamSessionConfig`, `DreamSessionSnapshot`, `DreamSessionController` actor, `DreamAnalysisPredicting` protocol, `DreamAnalysis`, `Analogy`, `PrimerStyle`, `SleepSessionRecord`, `SessionEvent`, `TMRBudget`, `SafetyEnforcer`, `AudioFeedbackProtocol`, `CalibrationRecord`.
- `BCIClassifier` gains: `CoreMLSleepStageClassifier`, `MockSleepStageClassifier`, `SleepStageLabels` mapping.
- `BCIAudio` (NEW target): `AVAudioEngine` wrapper implementing `AudioFeedbackProtocol`, calibration tone generator, TMR cue player, gentle-wake alarm, fade-in/fade-out envelope.
- `BCILLM` gains: prompt templates for primer generation and dream analysis. No new MLX dependency.
- `NeuralComposeApp` gains: session wizard, recall UI, analysis viewer.
- `BCIBridge`, `BCIEEG`, `BCICore` (existing communication-mode types) are unchanged.

**Data flow summary** (per-night, ~4 hours of recording):

- EEG: 4 ch × 256 Hz × 4 bytes × 14400 s = ~56 MB raw. Disk-buffered in 5-minute segments to bound data loss.
- Stage predictions: 1 per 5 s × 4 hours = 2880 predictions. ~150 KB total in memory.
- Smoother history: 60 epochs (30 min) × ~50 bytes = 3 KB. Negligible.
- TMR events: ≤5 per night × ~200 bytes = 1 KB. Negligible.
- Audio: 1 primer (2-5 min pre-generated) + 5 TMR cues × 3 s + 1 wake alarm (≤30 s) ≈ 6 MB. In-memory.

---

## §3 Sequence Diagrams

### §3.1 Sleep session lifecycle

```
   User            NeuralComposeApp       DreamSessionController       SleepSessionFSM
    │                     │                        │                          │
    │ start session       │                        │                          │
    │ (config, AC OK,     │                        │                          │
    │  Muse paired)       │                        │                          │
    │────────────────────▶│ start(config)          │                          │
    │                     │───────────────────────▶│                          │
    │                     │                        │ step(.primerStart)       │
    │                     │                        │─────────────────────────▶│
    │                     │                        │                          │ .startPrimer
    │                     │                        │◀─────────────────────────│
    │                     │                        │ play(primer audio)       │
    │                     │                        │ ─── BCIAudio ───         │
    │                     │                        │                          │
    │                     │                        │ (primer completes)      │
    │                     │                        │──▶ step(.primerComplete) │
    │                     │                        │   .beginIncubation       │
    │                     │                        │                          │
    │                     │                        │ (EEG arrives, classified)│
    │                     │                        │──▶ step(.smoothed)       │
    │                     │                        │                          │
    │                     │                        │ (alpha dropout: N1)      │
    │                     │                        │──▶ step(.smoothed)       │
    │                     │                        │   .enterSleep            │
    │                     │                        │                          │
    │                     │                        │ (N2_N3 sustained 5 min)   │
    │                     │                        │──▶ step(.smoothed)       │
    │                     │                        │   .playTMRcue (1/N)       │
    │                     │                        │                          │
    │                     │                        │ (TMR cue completes)      │
    │                     │                        │──▶ step(.cueComplete)    │
    │                     │                        │                          │
    │                     │                        │ ... up to 5 TMR cues ...  │
    │                     │                        │                          │
    │                     │                        │ (REM/UNCERTAIN_REM or    │
    │                     │                        │  sustained Wake)         │
    │                     │                        │──▶ step(.smoothed)       │
    │                     │                        │   .initiateWake          │
    │                     │                        │                          │
    │                     │                        │ play(gentle wake alarm)  │
    │                     │                        │──▶ step(.wakeComplete)   │
    │                     │                        │   .collectReport         │
    │                     │                        │                          │
    │  "voice or text"    │                        │                          │
    │────────────────────▶│ submitReport(text)     │                          │
    │                     │───────────────────────▶│                          │
    │                     │                        │──▶ step(.reportSubmitted)│
    │                     │                        │   .runAnalysis           │
    │                     │                        │                          │
    │                     │                        │   analyzeReport (LLM)    │
    │                     │                        │──▶ step(.analysisDone)   │
    │                     │                        │   .complete              │
    │                     │                        │                          │
    │  analysis           │                        │                          │
    │  (markdown)         │                        │                          │
    │◀────────────────────│ publish Snapshot        │                          │
    │                     │                        │                          │
```

### §3.2 EEG processing pipeline

```
   Muse S GATT       BCIBridge.dylib        BrainFlowService         EEGWindowing        SleepStaging       SleepStageSmoother
       │                    │                       │                       │                    │                    │
       │  notify            │                       │                       │                    │                    │
       │───────────────────▶│ drain_samples         │                       │                    │                    │
       │                    │──────────────────────▶│ AsyncThrowingStream   │                    │                    │
       │                    │                       │  yield(EEGSample)     │                    │                    │
       │                    │                       │──────────────────────▶│                    │                    │
       │                    │                       │                       │ append to ring     │                    │
       │                    │                       │                       │ on stride (5s)     │                    │
       │                    │                       │                       │ yield(SleepWindow) │                    │
       │                    │                       │                       │───────────────────▶│                    │
       │                    │                       │                       │                    │ Core ML inference  │
       │                    │                       │                       │                    │ (ANE, <100 ms)     │
       │                    │                       │                       │                    │ yield(Prediction)  │
       │                    │                       │                       │                    │───────────────────▶│
       │                    │                       │                       │                    │                    │ ring buffer
       │                    │                       │                       │                    │                    │ apply AASM rules
       │                    │                       │                       │                    │                    │ yield(Smoothed)
       │                    │                       │                       │                    │                    │──┐
       │                    │                       │                       │                    │                    │  │
       │                    │                       │                       │                    │                    │◀─┘
       │                    │                       │                       │                    │                    │ step(smoothed)
       │                    │                       │                       │                    │                    │──▶ SleepSessionFSM
```

Boundaries are async. Each `yield` is on its own actor's task; failures are surfaced via the stream's throwing terminator.

### §3.3 FSM transitions

```
                  ┌──────────┐
                  │  .idle   │◀────── reset / session abort
                  └────┬─────┘
                       │ start
                       ▼
              ┌──────────────────┐
              │ .primerPlayback  │──▶ userAbort ──▶ .idle
              └────┬─────────────┘
                   │ primerComplete
                   ▼
            ┌────────────────────┐
            │ .incubationMonitor │──▶ userAbort ──▶ .idle
            └────┬───────────────┘
                 │ smoothed == .n1 (alpha dropout, sustained 30s)
                 ▼
              ┌──────────────┐
              │  .deepSleep  │──▶ userAbort ──▶ .idle
              └────┬─────────┘
                   │ first .n2 after .n3 OR every 15 min in .n2_n3
                   │ (TMR budget allows; see §13 Safety)
                   ▼
              ┌─────────────┐
              │  .tmrWindow │──▶ userAbort ──▶ .idle
              └────┬────────┘
                   │ cueComplete
                   │ (loop back to .deepSleep if N2_N3 still)
                   ▼
              ┌──────────────────┐
              │ .wakeTransition  │──▶ userAbort ──▶ .idle
              └────┬─────────────┘
                   │ wakeComplete (gentle alarm finished)
                   ▼
            ┌─────────────────────┐
            │ .recallCollection   │──▶ userAbort ──▶ .idle (data saved)
            └────┬────────────────┘
                 │ reportSubmitted
                 ▼
              ┌─────────────┐
              │  .analysis  │──▶ userAbort ──▶ .idle (analysis saved partial)
              └────┬────────┘
                   │ analysisComplete
                   ▼
                  .idle (session ended, full record on disk)
```

Guard conditions (all enforced in code, not just documented):

- `.primerPlayback → .incubationMonitor`: primer fully played, no abort, audio engine returned success.
- `.incubationMonitor → .deepSleep`: 3+ consecutive N1 epochs AND alpha dropout ratio > 0.5 vs per-user baseline.
- `.deepSleep → .tmrWindow`: at least 1 N2_N3 epoch in past 5 epochs AND `TMRBudget.remaining > 0` AND `TMRBudget.minIntervalSatisfied`.
- `.tmrWindow → .deepSleep`: cue playback completed, return to N2_N3 within 30 s.
- `.deepSleep / .tmrWindow → .wakeTransition`: smoothed stage == .uncertain_rem OR .wake sustained for 5+ consecutive epochs OR explicit `.wakeNow` from user.
- `.wakeTransition → .recallCollection`: gentle alarm completed (or skipped if user manually woke).
- `.recallCollection → .analysis`: user submitted a report (text or voice) OR tapped "skip" (empty report recorded).
- `.analysis → .idle`: `DreamAnalysis` returned and persisted to `SleepSessionRecord`.

---

## §4 Hypothesis Registry

| # | Component | Scientific Status | Evidence Basis | Validation Needed |
|---|-----------|-------------------|----------------|-------------------|
| H1 | Alpha dropout detection (Wake → N1) | High | AASM sleep scoring; frontal alpha power correlates with wakefulness. Confirmed on this Muse: 3.08x eyes-closed alpha rise on TP9, 2.07x on AF7, 2.78x on TP10 (see `Recordings/muse_validation_20260710-004400.csv`). | Per-user baseline calibration. Validate dropout ratio threshold against PSG (not available without a sleep lab). |
| H2 | Sleep spindle detection (N2) | Medium | Spindles are weaker in frontal derivations than central, but detectable. Spindle-detection literature is robust. | Per-user validation against PSG or self-report. Spindle count vs subjective sleep depth over 5-10 sessions. |
| H3 | Slow wave detection (N3) | Medium | Frontal delta is actually *stronger* than central for slow waves (the literature notes this); Muse's 12-bit ADC quantizes at ~0.49 µV, which is adequate for delta-band detection. | Per-user delta power vs. subjective restedness. N2/N3 collapse simplifies the validation. |
| H4 | REM inference (no chin EMG) | Low | REM atonia is the defining criterion; Muse cannot measure it. Theta dominance + alpha absence is a weak proxy. | Requires EOG or chin EMG ground truth. The design outputs `.uncertain_rem` rather than `.rem` precisely to keep this honest. |
| H5 | Hypnagogic transition detection | Medium | Alpha dropout is a reliable N1 marker. Dormio validated a similar protocol (eyelid + HR, not EEG). | Measure false positive rate (cue triggered during wake) and false negative rate (missed N1) over 10+ sessions. |
| H6 | TMR cue timing (N2 / SWS) | Medium | TMR for declarative memory is established (Rasch & Born 2013); for creative insight, plausible but unproven. | Cue delivery should not cause arousal (validate via post-cue EEG desync detection); effect on creative insight requires D8. |
| H7 | LLM primer generation | Medium | Guided visualization is established; LLM-generated scripts are novel but testable. | Subjective engagement vs static primer (within-subject). D8 controls for this. |
| H8 | LLM dream-report analogy extraction | Low | NLP analogy extraction is active research. Dream reports are fragmented and noisy. | Requires user studies comparing LLM-extracted analogies to human-rater analogies. Cohen's κ on overlap. |
| H9 | Engineering insight improvement (full pipeline) | Low | No controlled studies for this specific pipeline. The D8 within-subject crossover exists precisely because of this. | The full D8 protocol. Pre-registration required. |
| H10 | Cross-domain generalization | Low | Single-domain validation (engineering) does not transfer to math, design, writing, etc. | Each domain requires its own D8-style study. Out of scope for v1. |
| H11 | Per-user calibration transfer across nights | Medium | Alpha baseline varies across nights with sleep pressure, caffeine, etc. Drift documented in literature. | Re-calibration protocol. Bootstrap alpha baseline from each session's eyes-closed windows if the user doesn't run a separate calibration. |
| H12 | TMR cue-sound audibility during sleep | Medium | Established that auditory thresholds rise during SWS but remain above 30 dB SPL for low-frequency content. | Per-user calibration tone. If user can't hear the calibration tone at the planned TMR volume, raise volume within the 60 dB SPL cap. |

---

## §5 Risk Register

| # | Risk | Likelihood | Impact | Mitigation |
|---|------|------------|--------|------------|
| R1 | Muse cannot reliably detect REM (no chin EMG) | High | Medium | Output `.uncertain_rem` rather than `.rem`; do not gate wake attempts on REM; rely on theta dominance + low-EMG + alpha absence for the *flag*, not a hard detection. |
| R2 | Domain shift from PSG datasets (central/occipital vs frontal) | High | High | Pre-train on `Sleep-EDFx` (197 recordings, central/occipital), fine-tune on the user's own Muse data with self-reported sleep stage labels. Until fine-tuning, publish per-class accuracy as <70% and require user interpretation. |
| R3 | Motion artifacts during overnight recording | High | Medium | Per-epoch quality check: RMS amplitude, line-noise ratio, drop-out counter. Reject epochs with >2 channels clipped (>500 µV sustained) or >10% samples saturated. Log rejected epochs to the session record. |
| R4 | Muse battery depletion over a full night | High (5h limit) | High | Cap session length to 4.5 hours by default; offer mid-session charge cable (Muse can charge while worn; document cable-noise mitigation); at 20% battery enter passive-recording mode; at 10% save and exit. |
| R5 | False hypnagogia detection triggering cues too early | Medium | High | Require 3+ consecutive N1 epochs at >0.7 confidence to enter `.incubationMonitor → .deepSleep`. Do not deliver TMR cues in `.incubationMonitor` — wait for `.deepSleep`. |
| R6 | False wake detection triggering dream report collection prematurely | Medium | High | Require 5+ consecutive Wake epochs at >0.8 confidence to initiate wake. If the system wakes the user but no report is collected within 5 minutes, fall back to passive recording. |
| R7 | MLX LLM latency too high for real-time primer generation | Low | Low | Primer is pre-sleep (one-shot, ≤30 s acceptable). Dream analysis is post-sleep (one-shot, ≤60 s acceptable). Neither is real-time. If latency exceeds budget, fall back to a static primer script. |
| R8 | Core ML model too large for ANE memory budget | Low | High | Target model size ≤30 MB. Validate on-device memory before deployment. Provide a `cpu_and_neural_engine` compute unit fallback if ANE compilation fails. |
| R9 | Sleep stage classifier accuracy insufficient for transition detection | Medium | High | Use a confidence-weighted smoother (see D3). Block transitions on low confidence. Never act on a single-epoch prediction. |
| R10 | User comfort / sleep disruption from EEG headband | High | High | Headband fit calibration pre-session. Pad-check at session start. Soft-fail to passive recording if RMS amplitude drifts to <5 µV on 2+ channels (likely headband removal). |
| R11 | M4 thermal throttle during Core ML inference | Low | Medium | Inference is <100 ms per 5 s epoch; thermal load is dominated by LLM. If `powermetrics` (sudo) shows sustained >85°C, drop to lower inference frequency (15 s stride). If no sudo, fall back to CPU-time heuristic. |
| R12 | Audio cues causing arousal (TMR side effect) | Medium | High | Validate post-cue EEG: if 3+ epochs in 30 s post-cue show alpha re-emergence at >0.6x eyes-closed baseline, treat the cue as arousing and reduce subsequent TMR frequency (next cue 30 min later instead of 15). |
| R13 | LLM-generated content includes harmful suggestions | Low | High | All analysis output is *labeled* as AI-generated and is for the user's own reflection. No automatic action. Content filter: refuse if the LLM response includes self-harm, harm-to-others, or medical advice language. |
| R14 | Mid-session app crash loses data | Medium | Medium | 5-minute disk-buffered segments (per Part 6a). On launch, scan for orphan session files and offer to resume. |
| R15 | Per-user calibration drift across nights | Medium | Medium | Re-establish alpha baseline from the first 30s eyes-closed window each session if a separate calibration is not run. Document the trade-off. |
| R16 | Demand characteristics (sham condition perceived as active) | Medium | Medium | D8 includes a blinding check: post-session, ask the participant which condition they believed they were in. Report compliance and any guess-vs-actual correlation. |

---

## §6 Safety Requirements

Each safety constraint is specified as: (a) the parameter, (b) the safe range, (c) what happens on violation, (d) how it's enforced in code. Code-level enforcement is mandatory; documentation alone is insufficient.

### §6.1 Audio safety

| Constraint | Safe range | Violation behavior | Code enforcement |
|---|---|---|---|
| Maximum cue volume | 60 dB SPL at ear (post-calibration reference) | Halt session | `SafetyEnforcer.assertVolumeWithinCap(_:)` called before every `play()`. `AVAudioPlayer.volume` set to a value derived from calibration reference; cap stored in `TMRBudget.volumeCap`. |
| Primer duration | ≤5 min | Trim or refuse to start | `DreamSessionConfig.primerDurationMinutes` validated against `SafetyEnforcer.MAX_PRIMER_DURATION` (300 s) in `start(config:)`. |
| TMR cue duration | ≤3 s | Truncate | `TMRBudget.cueDurationSeconds` ≤ 3.0. `AudioFeedbackProtocol.playTMRCue` accepts a `maxDuration: TimeInterval` parameter; refuses to start if exceeded. |
| Wake alarm duration | ≤30 s, with fade-in | Truncate + force-fade | `AudioFeedbackProtocol.playWakeAlarm` accepts `fadeInMs: Int ≥ 500`. `AVAudioPlayer` is wrapped to enforce a `AVAudioMixerNode` envelope. |
| Fade-in/out | ≥500 ms each | Reject audio file | `BCIAudio.PrimerValidator` checks the audio file's leading/trailing 500 ms; rejects if RMS shape indicates a hard start. |
| Audio interruptibility | ≤100 ms via Escape key, voice "stop"/"abort", or headband removal | Immediate stop | `AudioFeedbackProtocol` exposes a `cancel()` method. `DreamSessionController` wires it to (a) `NSEvent.addLocalMonitorForEvents(.keyDown)` for Escape, (b) `SpeechRecognizer` for voice (BCICore), (c) `BrainFlowService.signalLossHandler` for headband removal. |

### §6.2 Sleep disruption limits

| Constraint | Safe range | Violation behavior | Code enforcement |
|---|---|---|---|
| Max TMR cues per night | 5 | Enter passive recording | `TMRBudget.remaining` decremented in `playTMRcue`; assertion `> 0` before decrement. |
| Min interval between TMR cues | 15 min | Reject cue | `TMRBudget.minIntervalSatisfied(now:)` checks last cue time + 900 s ≤ now. |
| Max hypnopompic wake attempts per night | 2 | Enter passive recording | `TMRBudget.wakeAttempts` ≤ 2. |
| Sustained wake after cue/wake | >5 consecutive Wake epochs | Abort all cues, passive recording | `SleepSessionFSM` checks this on every `.smoothed` input; transitions to a "passive-only" sub-state. |
| Repeated awakening detection | 3+ wake events/night | Log warning, recommend specialist | `TMRBudget.wakeAttempts` ≥ 3 → `SessionAnalyzer` emits `userWarning: .consultSleepSpecialist`. |

### §6.3 Hardware safety

| Constraint | Safe range | Violation behavior | Code enforcement |
|---|---|---|---|
| Muse battery low | <20% | Passive recording only | `BrainFlowService` polls battery (or infers from connection health); `DreamSessionController` enters `.passiveOnly` mode. |
| Muse battery critical | <10% | Save and exit | `DreamSessionController` calls `saveAndExit(reason: .batteryCritical)`. |
| MacBook thermal | >85°C sustained 30 s | Reduce inference frequency | `ThermalMonitor` polls CPU pressure (`host_processor_info`) and process CPU time; if sustained >85% of any P-core for 30 s, `SleepStaging` stride extends from 5 s to 15 s. |
| MacBook thermal abort | >95°C | Save and exit | `ThermalMonitor` cannot read M4 SoC temp from userland. As a proxy: if `powermetrics` (sudo) is unavailable and CPU-pressure stays >95% for 60 s, treat as abort condition. |
| Data corruption recovery | 5-min disk segments | At most 5 min data loss | `EEGSampleWriter` rotates file every 300 s. On launch, `SessionRecovery` scans `~/Library/Application Support/NeuralCompose/Sessions/` for orphan files and offers resume. |
| Disk space pre-check | ≥2 GB free | Refuse to start | `DreamSessionController.start(config:)` calls `DiskSpaceProbe.freeBytes()`; throws `.insufficientDiskSpace` if < 2 GB. |

### §6.4 User safety

| Constraint | Safe range | Violation behavior | Code enforcement |
|---|---|---|---|
| User abort | Always available | Stop all, save partial | Three paths: (a) Escape key (`NSEvent` monitor), (b) voice "stop"/"abort" (`SpeechRecognizer`), (c) headband removal (signal-loss event from `BrainFlowService`). All three call `DreamSessionController.abort()`. |
| Repeated awakening warning | 3+ wake events/night | Log + user message | `TMRBudget.wakeAttempts` check in `SessionAnalyzer`. |
| Data privacy | Local only | No cloud call | `NetworkMonitor` enforces no outbound network during a session (defense-in-depth). All storage in `~/Library/Application Support/NeuralCompose/Sessions/`. |
| Data deletion | One action | Wipe all session data | `SettingsView` has "Delete all session data" button → `SessionStore.deleteAll()`. |
| Informed consent | First launch | Block session | `ConsentView` shown on first launch; user must acknowledge. Consent state stored in `UserDefaults` with `hasConsented: Bool` key. |

---

## §7 D1: Sleep stage model and prediction types

```swift
// Target: BCICore

/// 4-class sleep stage output. REM is collapsed into a low-confidence
/// "uncertain_rem" flag because Muse S cannot measure chin EMG.
public enum SleepStage: Int, CaseIterable, Codable, Sendable {
    case wake = 0
    case n1 = 1
    case n2_n3 = 2          // N2 and N3 are not reliably separable from frontal Muse
    case uncertain_rem = 3  // theta-dominant, low alpha; NOT a REM claim

    public var displayName: String {
        switch self {
        case .wake: return "Wake"
        case .n1: return "N1"
        case .n2_n3: return "N2/N3"
        case .uncertain_rem: return "Uncertain REM"
        }
    }

    /// Order in which the Core ML model outputs softmax values.
    public static let modelOutputOrder: [SleepStage] = [.wake, .n1, .n2_n3, .uncertain_rem]
}

// Target: BCICore
public struct SleepStagePrediction: Sendable, Codable {
    public let stage: SleepStage
    public let confidence: Float                    // max of softmax, [0,1]
    public let distribution: [SleepStage: Float]    // full 4-class softmax
    public let windowSequence: UInt64               // monotonic epoch counter
    public let endTimestamp: TimeInterval           // stream-relative, seconds
    public let epochStartTimestamp: TimeInterval
    public let qualityFlags: SleepEpochQuality      // motion, contact, etc.

    public init(
        stage: SleepStage,
        confidence: Float,
        distribution: [SleepStage: Float],
        windowSequence: UInt64,
        endTimestamp: TimeInterval,
        epochStartTimestamp: TimeInterval,
        qualityFlags: SleepEpochQuality
    ) { /* assign */ }
}

// Target: BCICore
public struct SleepEpochQuality: Sendable, Codable {
    public let rmsPerChannel: [Float]                  // µV
    public let saturatedFraction: Float                // [0,1] across all channels
    public let contactLoss: Bool                        // 2+ channels <5 µV
    public let motionArtifact: Bool                    // >500 µV transient
    public let lineNoiseRatio: Float                   // 50/60 Hz / total

    public var isUsable: Bool {
        !contactLoss && saturatedFraction < 0.1 && !motionArtifact
    }
}

// Target: BCICore
/// Extends the existing EEGFeatures with sleep-relevant computed features.
/// Band energies are kept from EEGFeatures; the new fields are derived.
public struct SleepFeatures: Sendable, Codable {
    // Inherited from EEGFeatures (computed once):
    public let bandEnergies: EEGFeatures
    // New derived fields:
    public let relativeBandPowers: [Band: Float]   // bandEnergies.X / sum(bandEnergies)
    public let alphaDropoutRatio: Float            // eyes-closed baseline / current alpha
    public let thetaAlphaRatio: Float              // theta / alpha, REM proxy
    public let betaAlphaRatio: Float               // beta / alpha, arousal proxy
    public let spindleCount: Int                   // detected in 11-15 Hz bursts
    public let slowWaveCount: Int                  // 0.5-2 Hz, >75 µV, ≥0.5 s
    public let emgProxyEnergy: Float               // >20 Hz broadband energy
    public let deltaFraction: Float                // delta / (delta + theta + alpha + beta)

    public enum Band: String, CaseIterable, Sendable, Codable {
        case delta, theta, alpha, beta, emg
    }
}
```

**Module ownership**:

| Type | Target Module |
|------|---------------|
| `SleepStage` | BCICore |
| `SleepStagePrediction` | BCICore |
| `SleepEpochQuality` | BCICore |
| `SleepFeatures` | BCICore |

**Design rationale**:

The 4-class output is non-negotiable. AASM 5-class scoring requires chin EMG for REM, and Muse S cannot measure it. Collapsing N2 and N3 into a single class is a deliberate honesty choice: distinguishing them on frontal channels at 256 Hz with a 12-bit ADC is below the documented accuracy floor in the literature. The user gets a clear "this is or is not sleep" signal; the system never claims more than the data supports.

`SleepFeatures` extends `EEGFeatures` rather than replacing it. The existing `FeatureExtractor` is preserved for the communication-mode path; the new sleep-specific features are computed on top of the same band energies. This avoids a feature-extractor fork and keeps the BCICore surface small.

**Confidence ratings**:

- `SleepStage` 4-class design: **High** (matches AASM scoring given the hardware constraint).
- `alphaDropoutRatio` per-user baseline: **Medium** (depends on calibration quality; drift across nights is documented in literature, mitigated by per-night bootstrap).
- `spindleCount` and `slowWaveCount` from frontal Muse: **Medium** (literature supports detection but at lower yield than central derivations; expect ~30-50% the rate of clinical PSG).
- `thetaAlphaRatio` as REM proxy: **Low** (this is a flag, not a detection; the design treats it as such).
- `emgProxyEnergy` from Muse S: **Low** (Muse S has no dedicated EMG channel; this is a broadband >20 Hz proxy on the EEG channels, which is contaminated by EEG harmonics).

**Limitations and unknowns**:

- Per-user calibration is essential. The literature is clear that alpha dropout is *relative*. Without a per-user baseline, dropout ratio is meaningless.
- The 4-class output does not support the AASM N1/N2/N3 distinction; the system can answer "is the user asleep" but not "are they in deep sleep specifically."
- Frontal-only Muse data has lower spindle yield than central derivations; the absolute spindle count should be interpreted as a *lower bound*, not a clinical count.

---

## §8 D2: Sleep staging protocol and Core ML classifier spec

```swift
// Target: BCICore
public protocol SleepStaging: Sendable {
    /// Classify a 30-second epoch of EEG into a SleepStagePrediction.
    /// Implementations may be async to allow ANE offloading.
    func classify(window: SleepWindow) async throws -> SleepStagePrediction
}

// Target: BCICore
/// A 30-second, 4-channel EEG window ready for sleep staging.
/// Distinct from EEGWindow to avoid coupling to communication-mode assumptions.
public struct SleepWindow: Sendable {
    public let samples: [[Float]]     // [channel][sample], 4 × 7680
    public let sampleRate: Double     // 256.0
    public let endTimestamp: TimeInterval
    public let sequence: UInt64

    public init(samples: [[Float]], sampleRate: Double,
                endTimestamp: TimeInterval, sequence: UInt64) { /* assign */ }
}

// Target: BCIClassifier
public final class CoreMLSleepStageClassifier: SleepStaging, @unchecked Sendable {
    public let model: MLModel                       // loaded from .mlmodelc
    public let inputShape: [Int]                    // [1, 4, 30, 128] for spectrogram input
    public let outputShape: [Int]                   // [1, 4]
    public let usesANE: Bool

    public init(modelURL: URL, computeUnits: MLComputeUnits = .cpuAndNeuralEngine) throws {
        // Compile the .mlmodelc, verify input/output shapes match spec.
    }

    public func classify(window: SleepWindow) async throws -> SleepStagePrediction {
        // 1. Bandpass 0.5-30 Hz per channel (NotchFilter at 50/60 Hz).
        // 2. Compute 4-second STFT (Hann, 50% overlap) → 4 × 30 × 128 magnitudes.
        // 3. Pack into MLMultiArray.
        // 4. Run model prediction on ANE.
        // 5. Decode softmax → SleepStagePrediction.
    }
}

// Target: BCIClassifier
public final class MockSleepStageClassifier: SleepStaging, @unchecked Sendable {
    public init(seed: UInt64 = 42) { /* deterministic synthetic */ }
    public func classify(window: SleepWindow) async throws -> SleepStagePrediction {
        // Returns stage sequences following a realistic hypnogram.
    }
}
```

**Module ownership**:

| Type | Target Module |
|------|---------------|
| `SleepStaging` (protocol) | BCICore |
| `SleepWindow` | BCICore |
| `CoreMLSleepStageClassifier` | BCIClassifier |
| `MockSleepStageClassifier` | BCIClassifier |

**Design rationale**:

Spectrogram input is preferred over raw EEG for the Core ML model. A 30s × 4ch × 128-bin spectrogram at 4 bytes is 60 KB per inference; raw would be 30 s × 4 × 256 × 4 = 122 KB. Spectrogram gives the model frequency-localized features that match the band-power heuristic of the existing `FeatureExtractor`. A small CNN (3-5 conv layers) on the spectrogram is a natural fit for ANE, which prefers fixed-shape 1D/2D inputs. Alternatives considered: (a) raw 1D conv on the waveform — simpler preprocessing but harder to interpret; (b) hand-crafted feature vector (band powers + ratios) → small MLP — interpretable but lower accuracy ceiling.

The mock classifier exists for the synthetic mode (no Muse, no ANE). It generates a deterministic hypnogram based on the time-since-session-start, useful for UI development and for validating the downstream pipeline without hardware.

**Training data recommendations**:

- **Primary dataset**: Sleep-EDFx (197 PSG recordings, 2 channels each at 100 Hz: Fpz-Cz and Pz-Oz). Channel mapping problem: Fpz-Cz is roughly *between* Muse's AF7 and AF8; Pz-Oz is far from any Muse electrode. Direct transfer is lossy. Mitigation: train on Fpz-Cz only (closest to Muse's frontal cluster), apply per-user fine-tuning.
- **Secondary dataset**: SHHS (5,000+ PSG recordings, more channels). Same channel-mapping problem.
- **Tertiary / future**: per-user labeled data from the user's own Muse + simultaneous self-reported sleep stage. Requires a calibration protocol; out of scope for v1.
- **Augmentation**: channel dropout, time-jitter (±5 s), additive Gaussian noise at 3-5 dB SNR, time-stretch (±5%). Critical for generalization across users and across nights.
- **Minimum dataset size**: 50 subjects × 8 hours = 400 hours of labeled data for first training run. The Fpz-Cz subset of Sleep-EDFx is 197 × 8 = ~1,500 hours — adequate for pretraining.

**Confidence ratings**:

- Sleep-EDFx pretraining transfer to Muse: **Low** (channel mapping is a major domain shift).
- Per-user fine-tuning improvement: **Medium** (literature supports; 5-10 sessions per user likely needed).
- Augmentation strategy effectiveness: **Medium** (standard practice; gains well documented).
- ANE inference latency: **High** (small CNN on 4-channel spectrogram is well within M4 ANE capability; <100 ms expected).

**Limitations and unknowns**:

- The channel mapping from Fpz-Cz (single bipolar derivation) to Muse's 4 unipolar channels (referenced to Fpz via the Muse's CMS/DRL) is not exact. We lose the differential that Fpz-Cz provides.
- Without per-user labeled data, the published accuracy from a Sleep-EDFx-trained model on Muse data is expected to be 60-70% (4-class, macro F1). This is below the threshold typically considered "useful" for clinical work, but adequate for the system's "is the user asleep" binary.
- The first deployment of this system will, by design, not be diagnostically useful. The system is for personal experimentation with the explicit caveat that any per-user accuracy claim is unverified.

---

## §9 D3: Sleep stage smoother

```swift
// Target: BCICore
public actor SleepStageSmoother {
    public struct Config: Sendable {
        public var historyEpochs: Int = 60          // 30 min at 30s epochs
        public var activationCount: Int = 3         // epochs before transition
        public var minConfidence: Float = 0.6
        public var overrideConfidence: Float = 0.9  // see below
        public var overrideEpochs: Int = 3          // see below
    }

    private var config: Config
    private var history: [SleepStagePrediction] = []
    private var lastEmitted: SmoothedSleepStage = .stage(.wake, confidence: 1.0)

    public init(config: Config = Config()) { /* assign */ }

    /// Ingest a new prediction. Returns a SmoothedSleepStage.
    public func ingest(_ prediction: SleepStagePrediction) -> SmoothedSleepStage {
        // 1. Drop low-quality epochs (qualityFlags.isUsable == false).
        // 2. Apply AASM transition rules: cannot skip stages (no Wake→N2_N3).
        // 3. Apply confidence-based override: if same stage at >0.9 confidence
        //    for 3+ consecutive epochs, allow it even if rules would block.
        // 4. Emit SmoothedSleepStage.
    }
}

// Target: BCICore
public enum SmoothedSleepStage: Sendable, Codable, Equatable {
    case stage(SleepStage, confidence: Float)
    case transition(from: SleepStage, to: SleepStage, at: TimeInterval)
}
```

**Module ownership**:

| Type | Target Module |
|------|---------------|
| `SleepStageSmoother` | BCICore |
| `SmoothedSleepStage` | BCICore |

**Design rationale**:

The smoother is the primary defense against single-epoch misclassifications. Sleep stage transitions are slow (minutes), and the 5s-stride 30s-epoch predictions will produce noisy boundaries. The AASM transition rules (`Wake → N1 → N2_N3` and reverse) are enforced at this layer. A confidence-based override exists because real sleep can have brief anomalies (e.g., a micro-arousal during N2) that the rules would block but the high confidence indicates is real.

The history size (60 epochs) matches the 30-minute sleep-cycle length. This gives the smoother enough context to detect sustained stage presence without being dominated by overnight drift.

**Confidence ratings**:

- AASM transition rule enforcement: **High** (this is the published standard).
- 3-epoch activation threshold: **Medium** (90 s of sustained prediction; literature supports 1-5 min sustained-stage windows for N1 onset; 90 s is on the fast side).
- Override at 3 epochs at >0.9 confidence: **Medium** (defensive against classifier errors; the threshold is a guess, will tune on real data).

**Limitations and unknowns**:

- The smoother does not have a "next-likely-stage" output. If the system needs to predict where the user is heading (e.g., to gate a TMR cue), a separate `SleepStagePredictor` is needed. Out of scope for v1.
- The override threshold (0.9 / 3 epochs) is a heuristic without published validation. Will be tuned on the user's own data.

---

## §10 D4: Sleep session FSM

```swift
// Target: BCICore
public enum SleepSessionPhase: String, Sendable, Codable {
    case idle
    case primerPlayback
    case incubationMonitor
    case deepSleep
    case tmrWindow
    case wakeTransition
    case recallCollection
    case analysis
}

public enum SessionInput: Sendable {
    case smoothed(SmoothedSleepStage)
    case timerTick(at: TimeInterval)
    case primerComplete
    case cueComplete
    case wakeAlarmComplete
    case dreamReportSubmitted(text: String)
    case analysisComplete(result: DreamAnalysis)
    case userAbort(reason: AbortReason)
    case reset
}

public enum SessionAction: Sendable {
    case noop
    case startPrimer
    case beginIncubation
    case enterSleep
    case playTMRcue
    case initiateWake
    case collectReport
    case runAnalysis
    case abort(reason: AbortReason)
}

public enum AbortReason: String, Sendable, Codable {
    case userEscape
    case voiceCommand
    case headbandRemoved
    case batteryLow
    case batteryCritical
    case thermalLimit
    case diskFull
    case tmrBudgetExhausted
    case wakeLimitReached
    case sessionTimeout
    case unknownError
}

public struct SleepSessionFSM: Sendable {
    public let config: DreamSessionConfig
    public let tmrBudget: TMRBudget

    public init(config: DreamSessionConfig, tmrBudget: TMRBudget) { /* assign */ }

    public func step(_ input: SessionInput, current: SleepSessionPhase) -> SessionAction {
        // Pure function. State machine. See §3.3 for transition table.
    }
}
```

**Module ownership**:

| Type | Target Module |
|------|---------------|
| `SleepSessionPhase` | BCICore |
| `SessionInput` | BCICore |
| `SessionAction` | BCICore |
| `AbortReason` | BCICore |
| `SleepSessionFSM` | BCICore |

**Design rationale**:

The FSM is a value type, not an actor. State is in the `current` parameter passed to `step(_:current:)`. This makes the FSM pure, testable, and free of concurrency concerns. The actor layer (in `DreamSessionController`) owns the mutable state and calls `step` on each input.

The transition rules in §3.3 are the implementation contract. They are written as a `switch` over `(current, input)` returning a single action. The smoother's `transition(from:to:at:)` case is the only place where the FSM gates on transitions rather than steady-state stages.

**Confidence ratings**:

- FSM transition table correctness: **High** (this is a pure-function lookup, no estimation).
- 3-epoch N1 threshold for `enterSleep`: **Medium** (90 s of sustained N1; some users fall asleep faster, some slower; the design is conservative).
- "N2_N3 sustained 5 min" for `playTMRcue`: **Medium** (5 min is a guess; literature on TMR cueing typically uses sustained N2/SWS for 1-10 min before cueing).

**Limitations and unknowns**:

- The FSM does not model "user already in deep sleep at session start" (e.g., if the system begins recording after the user has been asleep for 30 min). This is a real case; out of scope for v1.
- The transition table is hand-coded. Future versions may use a learning-based policy; out of scope.

---

## §11 D5: Dream session controller

```swift
// Target: BCICore
public struct DreamSessionConfig: Sendable, Codable {
    public let sessionID: UUID
    public let createdAt: Date
    public let problemDescription: String      // structured, from the user
    public let primerStyle: PrimerStyle
    public let primerDurationMinutes: Int     // <= 5
    public let tmrCueAudioPath: String        // path to .wav/.m4a
    public let wakeMethod: WakeMethod
    public let maxSessionDuration: TimeInterval   // seconds, default 4.5 * 3600

    public enum WakeMethod: String, Codable, Sendable {
        case gentleAudio
        case vibration                // not supported on Muse; uses iPhone
        case silent                   // for "wake without alarm" research condition
    }
}

public enum PrimerStyle: String, Codable, Sendable, CaseIterable {
    case guidedVisualization       // vivid scene, sensory
    case sensoryMetaphor           // abstract problem shape as concrete scene
    case constraintRelaxation      // drop one constraint, see what emerges
}

public actor DreamSessionController {
    public let config: DreamSessionConfig
    public let eegStream: any EEGStreaming
    public let staging: any SleepStaging
    public let smoother: SleepStageSmoother
    public let fsm: SleepSessionFSM
    public let audio: any AudioFeedbackProtocol
    public let dreamAnalysis: any DreamAnalysisPredicting
    public let recorder: SessionRecorder       // writes EEG + events to disk

    public init(
        config: DreamSessionConfig,
        eegStream: any EEGStreaming,
        staging: any SleepStaging,
        smoother: SleepStageSmoother,
        fsm: SleepSessionFSM,
        audio: any AudioFeedbackProtocol,
        dreamAnalysis: any DreamAnalysisPredicting,
        recorder: SessionRecorder
    ) { /* assign */ }

    public func start() async throws
    public func abort() async
    public func submitDreamReport(_ text: String) async throws
    public var snapshots: AsyncStream<DreamSessionSnapshot> { get }
}

public struct DreamSessionSnapshot: Sendable, Codable {
    public let phase: SleepSessionPhase
    public let smoothed: SmoothedSleepStage?
    public let timeInPhase: TimeInterval
    public let signalHealth: SignalHealthSummary
    public let lastDreamReport: String?
    public let tmrBudget: TMRBudgetSnapshot

    public struct SignalHealthSummary: Sendable, Codable {
        public let meanRmsPerChannel: [Float]
        public let contactLoss: Bool
        public let motionArtifactCount: Int
    }

    public struct TMRBudgetSnapshot: Sendable, Codable {
        public let remaining: Int
        public let wakeAttempts: Int
        public let lastCueAt: TimeInterval?
    }
}

// Target: BCIAudio (new)
public protocol AudioFeedbackProtocol: Sendable {
    func playPrimer(audioPath: String, fadeInMs: Int) async throws
    func playTMRCue(audioPath: String, maxDuration: TimeInterval, fadeInMs: Int) async throws
    func playWakeAlarm(fadeInMs: Int) async throws
    func cancel() async
    func calibrate(referenceTonePath: String) async throws -> CalibrationRecord
}

public struct CalibrationRecord: Sendable, Codable {
    public let referenceVolume: Float       // 0..1, system-relative
    public let timestamp: Date
    public let ambientNoiseFloor: Float?     // optional, mic-based
}
```

**Module ownership**:

| Type | Target Module |
|------|---------------|
| `DreamSessionConfig` | BCICore |
| `DreamSessionController` | BCICore |
| `DreamSessionSnapshot` | BCICore |
| `AudioFeedbackProtocol` | BCICore |
| `CalibrationRecord` | BCICore |
| `TMRBudget` | BCICore (see §6) |
| `AVAudioEngine` impl of `AudioFeedbackProtocol` | BCIAudio (new target) |

**Design rationale**:

The controller is the actor that owns the session's mutable state. It coordinates: (a) starting the EEG stream, (b) feeding predictions into the smoother, (c) feeding smoothed stages into the FSM, (d) executing FSM actions (audio, recording, etc.), (e) collecting dream reports, (f) running post-session analysis.

The snapshot stream is the UI's only window into the session state. The UI is read-only; the controller is the single source of truth. This is the same pattern as `TextCompositionController` in the existing communication-mode pipeline.

The audio protocol is an abstraction so the UI layer (or tests) can swap implementations. A mock implementation is trivial; a real implementation is `BCIAudio` using `AVAudioEngine`.

**Confidence ratings**:

- Actor-based state ownership: **High** (standard pattern in the existing codebase).
- Snapshot stream frequency: **High** (one snapshot per FSM step; bounded rate).
- Calibration step (system-relative dB): **Medium** (software-relative is not absolute dB SPL; user must understand the limitation).

**Limitations and unknowns**:

- No multi-night continuity in v1. Each session is independent; per-user alpha baseline is bootstrapped from the first 30s of eyes-closed each session.
- The audio calibration is software-relative. If the user changes headphones mid-session, the calibration is invalid.

---

## §12 D6: Dream analysis LLM protocol

```swift
// Target: BCICore
public protocol DreamAnalysisPredicting: Sendable {
    func generatePrimer(
        problemDescription: String,
        style: PrimerStyle
    ) async throws -> String

    func analyzeReport(
        dreamReport: String,
        problemContext: String,
        eegEvents: [SessionEvent]
    ) async throws -> DreamAnalysis
}

public struct DreamAnalysis: Sendable, Codable {
    public let extractedThemes: [String]
    public let potentialAnalogies: [Analogy]
    public let problemRelevance: Float           // 0..1, LLM self-rated
    public let suggestedReframings: [String]
    public let recommendedAction: String         // "Reflect on X", "Try Y", etc.
    public let contentFilterPassed: Bool         // no self-harm, no medical advice
}

public struct Analogy: Sendable, Codable {
    public let dreamElement: String              // "the river"
    public let problemElement: String            // "data flow"
    public let connection: String                // "both involve..."
    public let confidence: Float                 // 0..1
}

public struct SessionEvent: Sendable, Codable {
    public let timestamp: TimeInterval
    public let kind: EventKind
    public let payload: [String: String]

    public enum EventKind: String, Codable, Sendable {
        case phaseTransition
        case stageChange
        case cuePlayback
        case cueArousalDetected
        case dreamReportSubmitted
        case analysisComplete
        case abort
    }
}
```

**Module ownership**:

| Type | Target Module |
|------|---------------|
| `DreamAnalysisPredicting` | BCICore |
| `DreamAnalysis` | BCICore |
| `Analogy` | BCICore |
| `SessionEvent` | BCICore |
| `MLXDreamAnalysisPredicting` (impl) | BCILLM |

**Design rationale**:

Two distinct LLM tasks, with very different latency characteristics:

1. `generatePrimer` — pre-sleep, one-shot, ≤30 s acceptable. Input: structured problem description. Output: 2-5 minutes of spoken text. Style is one of three pre-defined shapes (`guidedVisualization`, `sensoryMetaphor`, `constraintRelaxation`).
2. `analyzeReport` — post-sleep, one-shot, ≤60 s acceptable. Input: dream report + problem context + EEG event timeline. Output: structured analysis with extracted themes, analogies, and reframings.

The protocol is in BCICore (pure-Swift, no MLX dependency). The implementation is in BCILLM (MLX-isolated). This matches the existing `NextWordPredicting` pattern.

The `contentFilterPassed` flag is a guardrail. The implementation must check the LLM output for self-harm, harm-to-others, or medical-advice language before persisting. If the filter fails, the analysis is still saved but marked; the UI shows a "filter flagged this content" warning.

The `eegEvents` argument is what makes this analysis different from generic dream interpretation. The LLM sees the stage timeline alongside the report, so it can say "the river imagery was reported during a stage classified as N2 at T+47 min" — a concrete anchor, not free-association.

**Confidence ratings**:

- LLM primer generation subjective quality: **Medium** (testable; user study needed).
- LLM analogy extraction agreement with human raters: **Low** (this is the novel claim; D8 evaluates it).
- LLM-content safety filtering: **Medium** (filtering rules are well-established; LLM-specific edge cases remain).

**Limitations and unknowns**:

- The protocol does not specify *which* MLX model is used. The current BCILLM is the imagined-speech LLM (likely a small instruction-tuned model). A larger model may be needed for coherent primer generation. This is an open question; the v1 design assumes a single LLM with a system-prompt switch for primer vs. analysis.
- The LLM's `problemRelevance` is self-rated. This is not a calibrated number; treat as LLM's "I think this is relevant" signal, not a measurement.

---

## §13 D7: Post-sleep analysis pipeline

```swift
// Target: BCICore
public struct SleepSessionRecord: Sendable, Codable {
    public let sessionID: UUID
    public let createdAt: Date
    public let config: DreamSessionConfig
    public let eegRecordingPath: String         // 5-min segments concatenated
    public let eventLog: [SessionEvent]
    public let stageTimeline: [SleepStagePrediction]   // 5s stride
    public let dreamReports: [String]           // raw + final
    public let analysisResults: [DreamAnalysis] // one per report
    public let sessionDuration: TimeInterval
    public let abortReason: AbortReason?
    public let signalHealthSummary: SignalHealthSummary
}

public actor SessionAnalyzer {
    public init() {}

    /// Run after the session ends. Reads the session record and produces
    /// a markdown summary + JSON sidecar.
    public func analyze(_ record: SleepSessionRecord) async throws -> SessionAnalysisOutput

    public struct SessionAnalysisOutput: Sendable, Codable {
        public let markdownSummary: String        // human-readable
        public let jsonSidecar: String           // structured
        public let correlations: [EEGContentCorrelation]
    }

    public struct EEGContentCorrelation: Sendable, Codable {
        public let dreamElement: String
        public let stageAtReport: SleepStage
        public let stageConfidence: Float
        public let timeOffsetMinutes: Float
    }
}
```

**Module ownership**:

| Type | Target Module |
|------|---------------|
| `SleepSessionRecord` | BCICore |
| `SessionAnalyzer` | BCICore |

**Design rationale**:

The session record is the persistent artifact. Every session writes one record to `~/Library/Application Support/NeuralCompose/Sessions/<sessionID>/`. The directory contains: `eeg.bin` (5-min segments), `events.jsonl` (event log), `stages.jsonl` (per-epoch predictions), `reports.txt` (dream reports), `analysis.md` (markdown summary), `analysis.json` (sidecar).

The `SessionAnalyzer` is a post-sleep actor. It reads the record and produces the markdown summary. The correlation logic ("report mentions water imagery — this occurred during N2 epoch 47, 23 min after sleep onset") is straightforward string matching + timeline lookup. It is not a deep analysis; it is a structured cross-reference.

**Confidence ratings**:

- Per-session record completeness: **High** (the record is just data; no estimation).
- Cross-reference correlation: **Medium** (string matching is brittle for dream content; better would be a topic model, but that's a separate effort).

**Limitations and unknowns**:

- The analyzer does not do long-term pattern tracking across sessions. Multi-session pattern analysis is out of scope for v1; would require a separate component.
- The markdown summary template is hand-written. Future versions may LLM-generate the summary, which would be a much better user experience but introduces a new LLM call (extra latency, content-filter concerns).

---

## §14 D8: Experimental evaluation plan

This section describes a **pilot feasibility study**, not a definitive trial. The N=30 target is appropriate for assessing whether the platform can be operated as designed and whether the active-vs-sham-vs-control design produces measurable differences; it is not adequately powered to establish moderate effects in a population. Definitive conclusions about engineering insight improvement require a larger follow-on study.

The pilot's primary deliverable is the **platform itself** — an open-source, privacy-preserving EEG-guided cognitive incubation system using consumer-grade hardware. Any improvements in creative problem solving are empirical questions to be tested, not claims baked into the software. The system should ship and be useful even if H1 in §14.1 turns out to be false.

### §14.1 Hypotheses

Each is stated as a testable null/alternative pair.

- **H1**: Participants who use the full incubation pipeline (primer + hypnagogia detection + TMR + dream report + LLM analysis) produce more novel solutions to a pre-registered engineering problem than participants who sleep normally.
  - H0: novelty_active = novelty_control
  - H1: novelty_active > novelty_control
- **H2**: The LLM-generated primer produces dream reports with higher problem-relevance than a static control primer.
  - H0: relevance_LLMprimer = relevance_staticprimer
  - H1: relevance_LLMprimer > relevance_staticprimer
- **H3**: Dream reports collected immediately after hypnopompic transition contain more actionable analogies than reports collected after a full night's sleep.
  - H0: actionableHypnopompic = actionableNatural
  - H1: actionableHypnopompic > actionableNatural
- **H4**: The LLM's analogy extraction from dream reports has non-trivial agreement with human raters.
  - H0: κ_LLM-human = 0
  - H1: κ_LLM-human > 0.4 (Cohen's κ, "moderate" agreement)

### §14.2 Experimental design

- **Within-subject crossover** (each participant serves as their own control). Reason: between-subject designs need large N to control for inter-individual variance in sleep architecture and dream recall. Within-subject with 3 conditions gives the same statistical power at ~1/3 the N.
- **Three conditions**, each on a separate night, order counterbalanced via Latin square:
  1. **Active**: full pipeline — LLM primer, hypnagogia detection, TMR cue during N2, hypnopompic wake, dream report, LLM analysis.
  2. **Sham**: same hardware setup, same primer playback, no TMR cue, no timed wake. Participant sleeps through the night, reports dreams upon natural waking.
  3. **Control**: no hardware, no primer, normal sleep. Participant reports dreams upon natural waking.
- **Washout period**: minimum 48 hours between conditions. Rationale: prior night's sleep affects next-night architecture; 48h reduces carryover.
- **Problem assignment**: each night gets a different engineering problem of comparable difficulty. Problems are pre-rated by 3 independent judges on a 1-5 difficulty scale; only problems within ±0.5 of mean difficulty are used. Each participant sees each problem in a different condition (counterbalanced).

### §14.3 Sample size

- Power analysis: medium effect size (Cohen's d = 0.5), α = 0.05, β = 0.80, within-subject 3-condition design.
- Required N for primary H1: ~20 complete sessions. **Note**: this is the threshold for *detection* of a medium effect; the estimate of the effect size itself will have wide CIs at N=20-30. The pilot is feasibility, not confirmatory.
- Attrition budget: hardware failures, poor sleep quality, missed reports, dropouts. Estimated 30-40% attrition. Target enrollment: N = 30.
- Maximum enrollment: N = 40 (stopping criterion).

### §14.4 Outcome measures

- **Primary**: novelty score of post-sleep solution to the engineering problem.
  - Rated blind by 3 independent domain experts on a 5-point Likert scale.
  - Inter-rater reliability reported as Fleiss' κ.
  - "Novelty" defined as: solution includes at least one element not in the standard solution space for the problem (judge-evaluated).
- **Secondary**:
  - Dream report problem-relevance score (rated blind by 3 raters).
  - Number of distinct analogies extracted by LLM vs. human raters.
  - Subjective sleep quality (PSQI + post-session questionnaire).
  - Participant blinding check: post-session, ask which condition they believed they were in. Report compliance.
- **Exploratory**:
  - EEG spectral correlates of dream report content (theta power during N2 vs. relevance).
  - Correlation between sleep stage duration and insight quality.
  - LLM analysis accuracy vs. human rater agreement (pre-registered comparison).

### §14.5 Control for confounds

| Confound | Control |
|---|---|
| Placebo effect | Sham condition (hardware + primer, no TMR / timed wake) |
| Order effects | Latin square counterbalance of condition order |
| Problem difficulty | Pre-rated problems, randomized assignment |
| Sleep quality | PSQI screening at enrollment; exclude diagnosed sleep disorders |
| Familiarity | Exclude problems the participant has worked on in past week |
| Time of night | Standardize session start time (±30 min) |
| Dream report demand characteristics | "Free recall, no right answers" prompt; raters blind to condition |

### §14.6 Statistical analysis plan

- **Primary analysis**: repeated-measures ANOVA (condition × outcome) with Greenhouse-Geisser correction.
- **Post-hoc**: paired t-tests with Bonferroni correction (3 comparisons).
- **Effect sizes**: Cohen's d with 95% CI.
- **Bayesian alternative**: Bayes factors for primary hypothesis (BF10 > 3 as evidence for H1).
- **Pre-registration**: the full analysis plan must be registered on OSF or equivalent before data collection begins. Pre-registration is non-negotiable; without it, the results are anecdotal.

### §14.7 Stopping criteria

- **Interim analysis** after N = 10 complete sessions: stop for futility if observed effect size d < 0.1.
- **Maximum enrollment**: N = 40 complete sessions.
- **Stopping for harm**: if any participant reports clinically significant sleep disruption (PSQI increase > 3 points) or any safety-relevant event (forced awakening causing distress, equipment failure during sleep), pause and review.

### §14.8 Limitations to state explicitly

- Small N (target N=30, max N=40) limits generalizability.
- Single-site, single-hardware (Muse S).
- Engineering problem-solving is a narrow domain; results may not transfer to other creative domains.
- The sham condition still involves wearing a headband, which may affect sleep quality differently from the no-hardware control.
- Dream reports are inherently subjective and may be influenced by demand characteristics.
- The LLM in the loop is a moving target; the system used at study start is not the system used at study end. Document the model version per session.

### §14.9 Confidence ratings

- H1 within-subject crossover design: **High** (this is a standard design for this type of question).
- H1 effect size d=0.5 assumption: **Medium** (no prior data; d=0.5 is conventional for medium effects but may be optimistic for a novel intervention).
- H4 LLM-human rater agreement target (κ > 0.4): **Medium** (the threshold is conventional; the LLM may or may not reach it).
- Pre-registration commitment: **High** (this is a process requirement, not a measurement).

---

## §15 Offline vs Runtime Separation

### §15.1 Offline (runs once or rarely, on developer machine)

- **Dataset preparation**:
  - Download Sleep-EDFx, SHHS, or similar.
  - Channel mapping: Fpz-Cz → 4 Muse channels via learned linear transform.
  - Epoch extraction: 30s windows, AASM labels.
  - Augmentation: channel dropout, time-jitter, additive noise.
- **Feature engineering**:
  - Bandpass filter bank (0.5-30 Hz + notch at 50/60 Hz).
  - STFT (4s window, 50% overlap, Hann).
  - Magnitude compression (log).
- **Model training**:
  - Small CNN on 30s × 4ch × 128-bin spectrogram.
  - Train on Sleep-EDFx Fpz-Cz; fine-tune on per-user data.
  - Output: 4-class softmax.
- **Core ML conversion**:
  - Convert PyTorch model to Core ML via `coremltools`.
  - Quantize to FP16 for ANE.
  - Validate accuracy on held-out subjects.
- **Model validation**:
  - Subject-independent split.
  - Leave-one-subject-out (LOSO) cross-validation.
  - Confusion matrix, Cohen's κ, macro F1, per-class sensitivity/specificity.
  - Latency benchmark on M4 ANE: target <100 ms per epoch.
- **Prompt template authoring**:
  - `primer_<style>.md` (guidedVisualization, sensoryMetaphor, constraintRelaxation).
  - `analyze_report.md`.
  - Content filter rules.
- **Safety test corpus**:
  - Dream reports + LLM outputs known to trigger content filter.
  - Verify the filter catches each.

**Output of offline**: `sleep_stage_classifier.mlmodelc` (~10-30 MB), prompt templates, content filter ruleset. The runtime depends only on the compiled `.mlmodelc` and the templates.

### §15.2 Runtime (runs on the M4 during a sleep session)

- **Hardware path**:
  - Muse S GATT → Core Bluetooth (CPU) → BrainFlow dylib (CPU) → `BrainFlowService` Swift actor (CPU, 50ms poll).
  - `EEGWindowing` actor (CPU) → 30s epochs.
  - `SleepStaging` (ANE, via Core ML) → 4-class softmax.
  - `SleepStageSmoother` actor (CPU, in-memory).
  - `SleepSessionFSM` value type (CPU, called from `DreamSessionController`).
  - `DreamSessionController` actor (CPU) → publishes `DreamSessionSnapshot` via `BoundedAsyncChannel`.
  - `BCIAudio.AVAudioEngine` (CPU + audio DSP) → primer / TMR / wake.
  - MLX primer generation: one-shot, pre-sleep, ~10-30 s, GPU.
  - MLX dream analysis: one-shot, post-sleep, ~10-60 s, GPU.
- **What runs when**:
  - Pre-sleep (5 min before session): wizard, calibration, MLX primer generation.
  - Sleep (4-5 hours): EEG stream, windowing, classification, smoothing, FSM, audio cues, recording.
  - Wake: gentle alarm, dream report collection, MLX analysis.
  - Post-sleep: `SessionAnalyzer` produces markdown summary, record persisted.
- **What's NOT runtime**:
  - No model training.
  - No dataset access.
  - No network.

---

## §16 Training Plan

### §16.1 Dataset selection and channel mapping

- **Primary**: Sleep-EDFx (physionet.org). 197 PSG recordings, ~8 hours each. Two bipolar EEG channels: Fpz-Cz and Pz-Oz. 100 Hz sampling.
- **Channel mapping**: Muse has 4 unipolar channels (TP9, AF7, AF8, TP10) referenced to CMS/DRL at Fpz. Fpz-Cz on the PSG is *roughly* equivalent to the differential between Muse's frontal cluster (AF7+AF8 average) and a central reference, but the geometry differs. **Honest position**: this mapping is lossy. The first model trained on Sleep-EDFx Fpz-Cz will underperform when transferred to Muse data. Mitigation: per-user fine-tuning on labeled Muse data (a calibration protocol, out of scope for v1; required for any production use).
- **Subject-independent split**: 80/10/10 (train/val/test) at the subject level. No subject appears in more than one split.
- **LOSO cross-validation**: for the published accuracy number, use leave-one-subject-out across all 153 Sleep-EDFx subjects. This is the standard in the sleep staging literature.

### §16.2 Feature engineering pipeline

- **Input**: 30s × 4ch raw EEG.
- **Preprocessing**: 0.5-30 Hz bandpass (4th-order Butterworth), 50/60 Hz notch.
- **STFT**: 4-second window, 50% overlap, Hann. Output: 30s window has 14 STFT frames × 129 freq bins per channel.
- **Magnitude compression**: log1p.
- **Per-channel normalization**: z-score against the subject's own training data mean/std.
- **Output**: 4 × 14 × 129 spectrogram. Reshape to (1, 4, 14, 129) for CNN input.
- **Optional**: stack with delta (0.5-2 Hz), theta (4-8), alpha (8-13), beta (13-30) band power time series as auxiliary input.

### §16.3 Model architecture

- **Backbone**: small 2D CNN. Example:
  - Conv2D(4, 16, 3x3, ReLU) → MaxPool(2x2)
  - Conv2D(16, 32, 3x3, ReLU) → MaxPool(2x2)
  - Conv2D(32, 64, 3x3, ReLU) → AdaptiveAvgPool
  - Linear(64, 4) → Softmax
- **~500K parameters, ~5 MB FP32, ~2.5 MB FP16.** Within ANE memory budget.
- **Loss**: cross-entropy with class weights (1/N1, 2/N2, 2/N3, 1.5/REM, 0.5/Wake — sleep stages are imbalanced; N1 is rare; Wake dominates early recordings).
- **Optimizer**: Adam, lr=1e-3, cosine annealing.
- **Augmentation** (during training): channel dropout (p=0.1), time-jitter (±5 epochs), Gaussian noise (3-5 dB SNR), time-stretch (±5%).

### §16.4 Validation protocol

- **Primary metric**: Cohen's κ (inter-rater agreement with ground truth AASM labels).
- **Secondary metrics**: macro F1, per-class sensitivity/specificity, confusion matrix.
- **Acceptance threshold** (for the 4-class model): κ ≥ 0.55 on held-out Sleep-EDFx subjects.
  - Caveat: this is *below* the published 5-class PSG accuracy (κ ≈ 0.75). The 4-class collapse and channel mapping account for most of the loss. Below κ=0.55, the system should fall back to a 2-class ("asleep / awake") model.
- **Per-class sensitivity target**: Wake ≥ 0.85, N1 ≥ 0.40 (N1 is intrinsically hard), N2_N3 ≥ 0.70, Uncertain_REM ≥ 0.30.
- **Latency**: <100 ms per 30s epoch on M4 ANE.
- **Memory**: model <30 MB; inference working set <200 MB.

### §16.5 Calibration protocol

- **Pre-sleep calibration** (preferred, optional):
  - User sits in a quiet room, eyes closed for 60 seconds.
  - System records the 4-channel EEG and computes per-channel alpha-band (8-13 Hz) power.
  - Stored as `CalibrationRecord.alphaBaseline: [Float]` (4 values).
  - Used as the denominator for `alphaDropoutRatio`.
- **In-session bootstrap** (fallback, automatic):
  - During the primer playback (eyes-open audio attention), the first 30s of eyes-closed priming (or the first `.n1` transition) is used to bootstrap the alpha baseline.
  - Less accurate than pre-sleep calibration; subject to drift.
- **Per-night re-calibration**:
  - Optional: re-establish baseline from any sustained eyes-closed window during the session.

---

## §17 MVP / Recommended / Experimental

### §17.1 MVP — minimum viable sleep-cycle session

What's needed to run a first end-to-end test:

- [ ] Muse S live acquisition (verified ✓)
- [ ] 30s epoch windowing, 5s stride
- [ ] Sleep feature extraction (band powers, alpha dropout, theta/alpha ratio)
- [ ] Sleep stage classifier: 2-class only ("asleep" vs "wake") for the very first run
- [ ] Sleep stage smoother (single transition rule)
- [ ] Session FSM: 4 phases only (idle → primer → incubation → end)
- [ ] Primer playback (BCIAudio)
- [ ] Local EEG recording (5-min disk segments)
- [ ] Dream report collection (text only)
- [ ] Basic LLM primer generation (single style, `guidedVisualization`)
- [ ] Post-session event log export (JSON)
- [ ] Pre-flight checks: Muse paired, AC connected, disk space ≥2 GB
- [ ] Abort paths: Escape key, headband removal

### §17.2 Recommended — improvements for reliability

- [ ] 4-class sleep stage classifier (Wake, N1, N2_N3, Uncertain_REM)
- [ ] Confidence-weighted smoother with AASM transition rules
- [ ] Pre-sleep alpha baseline calibration
- [ ] Signal health monitoring (contact, motion, line noise)
- [ ] TMR cue playback during N2 (1 cue, no repeat)
- [ ] Hypnopompic wake attempt (gentle audio, 1 attempt)
- [ ] LLM dream analysis with analogy extraction
- [ ] All 5 safety requirements (volume cap, fade-in/out, abort, battery, thermal)
- [ ] Structured session record export (JSON + markdown)
- [ ] Content filter for LLM output
- [ ] `SessionAnalyzer` cross-reference (dream content vs. EEG timeline)

### §17.3 Experimental — features that are scientifically unproven

- [ ] REM inference accuracy improvements (no chin EMG, hard limit)
- [ ] TMR cue-stage optimization (which sleep stage to cue during, how often)
- [ ] Multi-night pattern tracking (insight correlates with sleep architecture trends)
- [ ] Adaptive primer generation (LLM adjusts primer based on prior session outcomes)
- [ ] Dream report ↔ EEG stage correlation analysis
- [ ] Vibration-based wake (requires iPhone companion app)
- [ ] Real-time EEG visualization during session (for debugging; not for the user)
- [ ] Cross-domain transfer (math, design, writing problem types)
- [ ] The D8 evaluation itself (everything in §14)

---

## §18 Integration Checklist

Order of implementation. Each step independently testable. The Sleep Validation Toolkit (§21) is the gate before any classifier work begins.

### Phase A — Acquisition is verified (already done)

1. **[DONE]** Verify live Muse acquisition through BrainFlow. RMS in expected physiological range, alpha rise observed on eyes-closed during the validation session. See `Scripts/validate-muse-physiology.py` and `Recordings/muse_validation_20260710-004400.csv`.
2. **[DONE]** Build NeuralCompose with `--with-brainflow` and confirm 9 dylibs alongside binary.
3. **[DONE]** Confirm `BrainFlowService` Swift path can stream from a live Muse. (The Python binding confirms the underlying C API; the Swift path is logically equivalent.)

### Phase B — Sleep Validation Toolkit (§21)

This phase is the gate. The toolkit is a debugging surface for every later component. Do not start classifier work until the toolkit is stable across multiple sessions.

4. **Add a continuous EEG plotter** to `BCIEEG`: a real-time view of all 4 channels with adjustable time window (default 5s). Plots to the SwiftUI debug view; not user-facing in v1.
5. **Add PSD (power spectral density) computation** on sliding 4-second windows. Output per-channel PSD over 0.5-40 Hz. Display as a heatmap.
6. **Add alpha/theta ratio tracking** per channel, per 30-second epoch. Used for the `thetaAlphaRatio` feature.
7. **Add a blink detector** (frontal-channel amplitude threshold + window-of-interest). Records blink events to the session log.
8. **Add a jaw-clench detector** (broadband >20 Hz energy rise). Records clench events.
9. **Add an electrode-quality monitor**: per-channel RMS, line-noise ratio, dropout counter. Flags any channel with sustained RMS <2 µV (likely disconnected) or sustained >300 µV (likely saturated).
10. **Add a line-noise monitor** (50/60 Hz peak relative to surrounding bands). Computes line-noise ratio per epoch.
11. **Add a signal-dropout detector** (zero-fills, NaN-style values, or sustained ADC rail-clipping). Records dropout events.
12. **Run the toolkit through 5+ sessions** of varying length (5 min, 30 min, 4 h). Confirm: (a) alpha rise is visible in eyes-closed windows, (b) blinks register as expected frontal transients, (c) jaw clench shows up as broadband energy rise, (d) electrode quality stays in physiological range for the duration, (e) line noise is consistent with the recording environment, (f) dropouts are rare.
13. **Lock the toolkit's APIs** (output types, event log format). Downstream components consume these.

**Gate to Phase C**: 5+ clean sessions through the toolkit, no false readings, all features observable. If alpha rise is not visible, or the per-user baseline cannot be established, fix the toolkit before moving on.

### Phase C — Sleep staging and FSM (D1-D5)

14. **Add `SleepWindowingConfig` preset** to existing `EEGWindowing` actor: 30s window, 5s stride, 4 channels. Validate against the toolkit's epoch boundaries.
15. **Add `SleepFeatures` computation** on top of existing `FeatureExtractor`. Validate against the toolkit's per-channel PSD and alpha/theta ratio.
16. **Add `SleepStage` and `SleepStagePrediction` types** (pure-Swift, no deps).
17. **Add `MockSleepStageClassifier`** producing a deterministic hypnogram. Tests: feed synthetic windows, verify plausible output.
18. **Add `SleepStageSmoother` actor** with AASM transition rules. Tests: feed synthetic stage sequences, verify smoothed output.
19. **Add `SleepSessionFSM` value type** with the transition table from §3.3. Tests: feed synthetic inputs, verify action sequence.
20. **Add `TMRBudget` actor** enforcing 5 cues/night max, 15 min min interval, 2 wake attempts.
21. **Add `BCIAudio` target**: `AudioFeedbackProtocol` + `AVAudioEngine` impl. Tests: `MockAudioFeedback` returning synthetic calibration record.
22. **Add `DreamSessionController` actor** wiring together the above. Tests: integration test with mocks for EEG, audio, LLM.
23. **Add `AudioFeedbackProtocol` mock** for the controller tests.
24. **Add `DreamAnalysisPredicting` protocol** + `MLXDreamAnalysisPredicting` (or stub).
25. **Add session wizard UI** (SwiftUI): consent flow, problem description, calibration step, primer style, start button.
26. **Add recall UI** (SwiftUI): text input for dream report.
27. **Add `SessionAnalyzer` actor** + markdown + JSON export.

### Phase D — End-to-end validation

28. **First end-to-end MVP test** with Muse. The user wears the Muse, runs a 30-minute nap session with a known-wake cue at 25 minutes. Goal: confirm a session runs to completion, recording works, dream report is captured, analysis is generated.
29. **Run 3+ MVP sessions** of increasing length (30 min, 1 h, 2 h). Validate: battery holds, signal stays clean, no crashes, the toolkit's features remain observable.
30. **First 4-5 hour test session** with the user. Validate: full Recommended-tier pipeline (primer + smoother + LLM analysis). This is the first time the design runs as designed.

### Phase E — Classifier training and integration (offline + runtime)

31. **Train Core ML classifier** (offline): Sleep-EDFx → Core ML. This step is independent of the runtime; it can be done in parallel.
32. **Replace `MockSleepStageClassifier` with `CoreMLSleepStageClassifier`** once model is trained. Validate: inference latency on M4 ANE <100 ms.
33. **Add per-user alpha baseline calibration** to the session wizard.
34. **Add TMR cue playback** to the session FSM (Recommended tier).
35. **Add hypnopompic wake** (gentle audio).
36. **Add LLM primer generation** (one-shot, pre-sleep). Requires MLX.
37. **Add LLM dream analysis** (one-shot, post-sleep). Requires MLX.
38. **Cross-check Python vs Swift** streams (in parallel with a Muse session): both write to disk; post-hoc comparison of timestamps, channel RMS, sample rate. Confirms no architecture drift.

### Phase F — D8 pilot feasibility study

39. **D8 pre-registration on OSF**. Non-negotiable. Without it, the results are anecdotal.
40. **D8 recruitment and run**. N=30 target, 3 conditions (Active / Sham / Control), within-subject crossover, 48h washout, pre-rated engineering problems.
41. **D8 analysis and reporting**. Pre-registered analyses, Cohen's d with 95% CI, Bayes factors, blinding check.

The MVP test (step 28) is the gate before Phase E. Phase F is independent of the runtime and can be planned in parallel from the start.

---

## §19 Open Questions

These cannot be resolved from the design alone. Each requires a user decision. Resolved items are recorded with the date of resolution.

1. **Which Muse model for the user?** **RESOLVED 2026-07-10: Muse S.** MUSE_S_BOARD=39 is the active board ID path. Muse 2 (board 38) and Muse S Athena (board 67) are forward-compat paths only.
2. **MacBook will be plugged in overnight?** **RESOLVED 2026-07-10: Yes.** The session wizard requires AC confirmation. The 4-5 hour session window is the design target.
3. **PSG datasets for training: Sleep-EDFx or SHHS?** Sleep-EDFx is smaller and better-documented; SHHS is larger but with more channel heterogeneity. Recommendation: Sleep-EDFx for v1.
4. **Per-user calibration protocol: pre-sleep session required, or in-session bootstrap sufficient?** The pre-sleep protocol adds a step and friction; the bootstrap is automatic but less accurate. Recommendation: optional pre-sleep, automatic fallback to bootstrap.
5. **TMR during N2 vs SWS?** Literature is mixed. Recommendation: N2_N3 collapse + 1 TMR per N2 epoch block (see §3.3). User can adjust.
6. **Wake method: gentle audio or silent?** Gentle audio is the published Dormio protocol. Silent is for research conditions. Recommendation: gentle audio, with silent as a config option.
7. **First-MVP Muse test: how long?** **Resolved 2026-07-10: 30-minute nap first, then 1-2 hour, then 4-5 hour.** This sequencing is now codified in §18 Phase D.
8. **D8 participants: self only, or with collaborators?** **OPEN**. The within-subject crossover design with N=30 implies recruiting participants. If user-only, the design collapses to a single-subject case study (still valuable, but cannot establish population effects). Recommendation: start as a single-subject feasibility case, expand to collaborators if H1 trend is encouraging at N=5-10 self.
9. **Content filter rules: how strict?** Self-harm, harm-to-others, medical advice. The threshold is a UX call; too strict = unhelpful analyses, too loose = safety risk. Recommendation: conservative defaults, user-tunable.
10. **What MLX model for primer + analysis?** **OPEN**. The current BCILLM is presumably a small instruction-tuned model. Primer generation needs strong narrative; analysis needs strong structured output. May require two models.
11. **OSF pre-registration of D8: who does it?** The user must commit to pre-registration before data collection. Without it, the results are anecdotal.
12. **Maximum acceptable session length, given Muse S battery?** **OPEN until empirically characterized.** The 4-5 hour target in §18 is the design assumption, but actual runtime depends on the specific Muse S firmware, age, and charge state. First step: measure actual runtime on the user's device with a continuous-stream recording. The validation toolkit (§21) is a natural place to capture this metric during Phase B sessions.

---

## §20 Cross-cutting Confidence Summary

| Aspect | Confidence | Justification |
|---|---|---|
| Live Muse S acquisition through BrainFlow | **High** | Verified 2026-07-10 on Muse S. RMS in expected physiological range, alpha rise observed on eyes-closed. The Muse 2 path is the same architecture; re-validation recommended as a one-time check. |
| Sleep Validation Toolkit stability | **High** | Each component is a small, well-defined signal-processing step. Mature tooling in this domain. |
| 30s epoch windowing, 5s stride | **High** | Standard choice in sleep literature. |
| Sleep stage 4-class model | **High** | Matches AASM given hardware constraint (no chin EMG). |
| Sleep stage classifier accuracy on Muse S data | **Low** | Channel mapping is a major domain shift (see §1.17). Per-user fine-tuning is the path. **Largest expected source of model error.** |
| AASM transition rules in smoother | **High** | Published standard. |
| Hypnagogia detection from frontal alpha dropout | **Medium** | Literature supports; per-user calibration essential. |
| TMR cue timing (N2 / SWS) | **Medium** | TMR for declarative memory is established; for creative insight is plausible but unproven. |
| LLM primer generation subjective quality | **Medium** | Testable via within-subject comparison. |
| LLM dream analogy extraction | **Low** | Novel; D8 evaluates. |
| 60 dB SPL audio cap | **Medium** | Software-relative, not absolute SPL; user must understand. |
| MacBook thermal threshold enforcement | **Medium** | Userland cannot read M4 SoC temp; CPU-pressure proxy is a heuristic. |
| Muse S battery 4-5 hour limit | **Medium** | Conservative; actual runtime depends on firmware/age. **OPEN: should be measured empirically in Phase B.** |
| D8 within-subject crossover | **High** | Standard design. |
| D8 effect size d=0.5 | **Medium** | No prior data; conventional default. |
| Per-user alpha baseline across nights | **Medium** | Drift documented; per-night bootstrap is the mitigation. |
| Content filter for LLM output | **Medium** | Filtering rules are well-established; LLM-specific edge cases remain. |
| M4 ANE inference <100 ms | **High** | Small CNN on 4-channel spectrogram is well within capability. |
| MLX primer ≤30 s | **High** | One-shot pre-sleep, latency budget is loose. |
| MLX dream analysis ≤60 s | **High** | One-shot post-sleep, latency budget is loose. |
| Engineering insight improvement (full pipeline) | **Low** | Unproven; D8 evaluates. |
| Pilot feasibility study at N=30 detects d=0.5 | **Medium** | The N=20-30 range detects medium effects but with wide CIs on the effect size itself. The pilot is feasibility, not confirmatory. |

---

*End of design document. Implementation order is §18 (Phases A-F). The Sleep Validation Toolkit (§21) is the gate before classifier work begins. Open questions in §19 must be resolved before D8 begins. The pre-registration of D8 is non-negotiable for the system's credibility.*

---

## §21 Sleep Validation Toolkit

This section is the **first thing to build** and the **gate before any classifier or downstream component work**. The toolkit is a debugging surface for every later component. Without a stable toolkit, classifier and FSM work is debugging in the dark.

### §21.1 Purpose

The toolkit is a set of small, independent signal-processing modules that consume raw Muse S EEG and produce observable, verifiable outputs. Each module is itself a confidence-building tool:

- The EEG plotter confirms the *signal exists* and the time axis is correct.
- The PSD module confirms the *frequency content* is what we expect (alpha peak in eyes-closed, theta in N1, etc.).
- The alpha/theta ratio tracker confirms a *feature the classifier will use* is observable on real data.
- The blink and jaw-clench detectors confirm *event detection* works on real signals.
- The electrode-quality monitor confirms *data integrity* across a full session.
- The line-noise monitor confirms the *environment* is not corrupting the data.
- The signal-dropout detector confirms *hardware reliability* over multi-hour sessions.

Without these, when the classifier fails, we cannot tell whether the failure is in (a) signal acquisition, (b) feature extraction, (c) the model, or (d) the test setup. With these, the failure mode is localizable in seconds.

### §21.2 Component list

| # | Component | Input | Output | Confidence of standalone correctness |
|---|-----------|-------|--------|-------------------------------------|
| 1 | Continuous EEG plotter | `EEGStream` | 4-channel time-series display | High (visualization only) |
| 2 | 3D neural workspace | `EEGStream` | SceneKit scene with 4 animated electrodes (alpha→emissive, theta→elevation, FSM→color) | High (visualization only) |
| 3 | PSD heatmap | `EEGWindow` (4s) | Per-channel spectrogram 0.5-40 Hz | High (Welch/FFT is standard) |
| 4 | Alpha/theta ratio tracker | `EEGWindow` (30s) | Per-channel ratio time series | High (band power is well-defined) |
| 5 | Blink detector | `EEGWindow` (1s) | Blink event log (timestamp, channel, amplitude) | High (frontal transient is canonical) |
| 6 | Jaw-clench detector | `EEGWindow` (2s) | Clench event log | Medium (EMG-in-EEG signature can be confused with broadband EEG) |
| 7 | Electrode-quality monitor | `EEGWindow` (1s) | Per-channel RMS, dropout flag, saturation flag | High (amplitude checks are well-defined) |
| 8 | Line-noise monitor | `EEGWindow` (4s) | 50/60 Hz peak / surrounding bands | High (FFT-based) |
| 9 | Signal-dropout detector | Raw `EEGStream` | Dropout event log (zero-fills, NaN-style, ADC rails) | High (threshold-based) |

### §21.3 Implementation notes

- All components consume from the existing `EEGWindowing` actor (extended with a `SleepWindowingConfig` preset) and the existing `BrainFlowService` (already verified live on the Muse S).
- Output is a stream of typed events to a `BoundedAsyncChannel`. The SwiftUI debug view subscribes and renders. Tests can subscribe programmatically.
- Each component is independently testable on synthetic data. The validation session on 2026-07-10 already produced physiological signals, so the live data tests are realistic.
- The toolkit is **not** the user-facing application. It is a developer tool. The user-facing flow does not show the toolkit unless the user explicitly opens the debug view.

### §21.4 Acceptance criteria

The toolkit is considered stable when:

1. **5+ sessions of varying length** (5 min, 30 min, 1 h, 2 h, 4 h) complete without crashes.
2. **Alpha rise on eyes-closed** is visible in the PSD heatmap and the alpha/theta ratio tracker. This is the most important signal-physiology confirmation.
3. **Blinks register** as expected frontal transients with peak amplitude in the 50-300 µV range.
4. **Jaw clench shows up** as broadband energy rise in the 20+ Hz range, distinguishable from baseline within 2 seconds of clench onset.
5. **Electrode quality** stays in the physiological range (RMS 5-100 µV per channel) for the duration of the session.
6. **Line noise** is consistent with the recording environment and does not vary by more than 2x across a session.
7. **Dropouts** are rare (≤1 per hour).
8. **Per-user alpha baseline** can be reliably established from a 30-second eyes-closed window.

If any of these fail, the toolkit is the bug surface. Fix the toolkit before moving to Phase C.

### §21.5 What the toolkit does NOT do

- It does not classify sleep stages. (Phase C.)
- It does not trigger TMR cues. (Phase C / D.)
- It does not run the session FSM. (Phase C.)
- It does not invoke the LLM. (Phase E.)

The toolkit's job is to make the raw signal trustworthy. Everything downstream consumes the toolkit's outputs.

### §21.6 Why this is the gate

The classifier in §8 (Core ML on Sleep-EDFx) is expected to underperform on Muse S data due to channel mapping (see §1.17). When it does, the question is: is the failure in the model, or is the Muse S data bad? The toolkit is what answers that question. Without the toolkit, every classifier failure is ambiguous. With the toolkit, classifier failures are localizable to the model itself, and the model is the only thing that needs iteration.

A second reason: the toolkit is reusable across all later experiments. Every sleep study, every TMR test, every LLM analysis comparison benefits from a stable, well-instrumented signal. Building the toolkit once and using it many times is the right economy.

A third reason: the toolkit itself is publishable as a debugging tool. "An open-source signal-quality monitoring toolkit for consumer-grade EEG" is a defensible contribution on its own. The pilot D8 study in §14 may not detect a meaningful effect at N=30 (the confidence is Medium for that), but the toolkit will be useful regardless of the D8 outcome.

---

## §22 Publication Framing

The system's primary contribution is the **platform itself**, not any specific claim about creative problem-solving. The defensible initial publication target is:

> **An open-source, privacy-preserving platform for EEG-guided cognitive incubation and dream-report analysis using consumer-grade hardware.**

This frames the work as engineering + applied cognitive science, not as a clinical intervention or a productivity tool. Any improvements in creative problem solving are *empirical questions to be tested*, not claims baked into the software. The system should ship and be useful even if H1 in §14.1 turns out to be false.

### §22.1 What the publication is

- **Type**: systems paper + open-source release.
- **Venue**: a venue that values reproducible infrastructure. Candidates: ACM CHI Late-Breaking Work, UbiComp/ISWC, JOSS (Journal of Open Source Software) for the toolkit, or a workshop at NeurIPS/ICML on open EEG tooling.
- **Contribution**: (1) the validated Muse S + BrainFlow + Core ML pipeline; (2) the Sleep Validation Toolkit (§21) as a reusable debugging surface; (3) the D8 pre-registered pilot feasibility study (§14); (4) the architectural design (§1-§18 of this document) as a reference for others building on consumer-grade EEG.
- **Reproducibility**: code on GitHub, dataset citations, pre-registration on OSF, raw data and analysis scripts archived.

### §22.2 What the publication is NOT

- Not a clinical-accuracy claim for sleep staging. The 4-class output and the channel-mapping caveat in §1.17 explicitly disclaim this.
- Not a "solve problems in your sleep" productivity claim. This is the speculative H9 in §4.
- Not a clinical or medical device. The user-facing flow makes this explicit at first launch (§6.4).
- Not a general-purpose Muse analysis tool. The scope is sleep-cycle mode of NeuralCompose.

### §22.3 Empirical claims the publication makes

| Claim | Confidence | Supported by |
|---|---|---|
| Live Muse S EEG acquisition through BrainFlow is reproducible on macOS | **High** | Validation on 2026-07-10 on Muse S. |
| Per-channel RMS, alpha power, and blink detection are observable on consumer Muse hardware in home settings | **High** | Toolkit §21; multiple sessions. |
| The architectural design accommodates 4-class sleep staging with a documented path to 5-class via per-user calibration | **Medium** | §1.17, §16, §21. |
| Within-subject crossover design with N=30 is feasible for a pilot | **Medium** | §14.3; depends on recruitment. |
| The platform runs end-to-end with a 4-5 hour session and battery, thermal, and audio safety constraints enforced | **Medium** | §18 Phase D; depends on actual Muse S runtime. |

### §22.4 Empirical claims the publication does NOT make

- That the full incubation pipeline improves engineering insight. This is H1 in §14.1, **Low confidence** until D8 runs.
- That the LLM produces useful dream analyses. H8 is **Low confidence**.
- That the system achieves clinical-grade sleep staging. The 4-class output and the channel-mapping caveat explicitly disclaim this.
- That Muse S can do 5-class AASM scoring. Muse S has no chin EMG; this is hardware-limited.

### §22.5 Why the framing matters

The strongest defense of the work is that the platform is useful regardless of D8's outcome. If H1 is true, the platform is a validated research instrument for further study. If H1 is false, the platform is a documented open-source failure mode, which is also a contribution (negative results are publishable when they are pre-registered and well-instrumented). Either way, the Sleep Validation Toolkit, the architectural design, and the open-source codebase remain useful.

This is the framing the user identified: a privacy-preserving, open-source platform for EEG-guided cognitive incubation and dream-report analysis. The empirical questions about whether the platform *works* are separate from the engineering work of *building* the platform. The user has committed to the engineering. The empirical questions are for the D8 pilot and follow-on studies.

