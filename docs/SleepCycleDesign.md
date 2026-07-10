# Sleep Cycle Design (Reader-Friendly Summary)

The full D1–D8 specification is at [`SLEEP_CYCLE_DESIGN.md`](../SLEEP_CYCLE_DESIGN.md) at the repo root. That document is the canonical type-level design — long, technical, and load-bearing for implementation. This document is the reader-friendly summary: it explains the design decisions, the open questions, and the implementation order, without reproducing the type signatures.

## What the System Does

1. **Detects when the user is falling asleep** by watching for an alpha-dropout event (alpha-band power dropping below the per-user eyes-closed baseline).
2. **Delivers audio cues (TMR)** during N2/SWS sleep stages. The cue is paired with a problem-specific sound (e.g., a tone, a spoken phrase) that was associated with the engineering problem during the pre-sleep primer.
3. **Wakes the user during a hypnopompic transition** (REM/uncertain_REM → wake) when dream recall is freshest.
4. **Collects the dream report** (text or voice-to-text) immediately.
5. **Runs LLM analysis** on the dream report, comparing it to the problem context, extracting themes and analogies.
6. **Surfaces the analysis** to the user for evaluation while fully awake.

The system does **not** solve engineering problems. It surfaces analogies and reframings for the user to evaluate. The user does the synthesis.

## The 4-Class Sleep Stage Model

Muse S has 4 unipolar frontal channels (TP9, AF7, AF8, TP10), no chin EMG, no EOG. AASM 5-class scoring is not achievable. The honest output is 4 classes:

- **Wake** — eyes-closed alpha present, beta present.
- **N1** — alpha dropout (alpha power < 50% of baseline), theta rising.
- **N2_N3** — N2 and N3 collapsed because distinguishing them requires central channels. Spindles (N2) and slow waves (N3) are detectable from frontal derivations but the boundary is fuzzy.
- **Uncertain_REM** — theta-dominant, alpha absent, EMG proxy low. **Not a REM claim** — we cannot measure atonia. The output is honest about this.

The system gates actions on these predictions but never claims clinical-grade staging.

## The Sleep Validation Toolkit (Phase B)

Before the sleep-mode architecture is built, the platform needs a debugging surface for the raw Muse S signal. The toolkit is eight small components that consume `EEGStream` and produce observable, verifiable outputs:

| # | Component | What it does | Why it matters |
|---|-----------|--------------|----------------|
| 1 | Continuous EEG plotter | 4-channel time-series display | "Is the signal alive?" |
| 2 | PSD heatmap | Per-channel spectrogram 0.5–40 Hz | "Are we seeing alpha in eyes-closed?" |
| 3 | Alpha/theta ratio tracker | 30s epoch, per-channel | A feature the classifier will use |
| 4 | Blink detector | Frontal transient | "Can we detect events?" |
| 5 | Jaw-clench detector | Broadband >20 Hz | "Is EMG contamination observable?" |
| 6 | Electrode-quality monitor | Per-channel RMS, dropout | "Is the headband still on?" |
| 7 | Line-noise monitor | 50/60 Hz peak / surrounding | "Is the environment clean?" |
| 8 | Signal-dropout detector | Zero-fills, ADC rails | "Is hardware reliable over hours?" |

The first component is shipped: `EEGScalpPlotterView` in `Sources/BCIEEG/`, a 3D depth-stacked time-series plotter with adjustable µV/px scale and z-depth spacing.

## The Session State Machine

The session is a finite-state machine with eight phases:

```
idle
  → primerPlayback
  → incubationMonitor     (waiting for alpha dropout)
  → deepSleep
  → tmrWindow
  → deepSleep             (loop back if N2_N3 sustained)
  → wakeTransition
  → recallCollection
  → analysis
  → idle
```

Transitions are guarded by:

- The smoothed sleep stage from the AASM-aware smoother.
- The `TMRBudget`: 5 cues/night max, 15-min min interval, 2 wake attempts.
- The user's abort (Escape key, voice command, headband removal).

The FSM is a value type. The actor layer (`DreamSessionController`) owns the mutable state and calls the FSM's pure `step(_:current:)` method.

## Safety Constraints (Code-Enforced, Not Just Documented)

The safety requirements in `SLEEP_CYCLE_DESIGN.md` §6 are enforced in code via a `SafetyEnforcer` and a `TMRBudget`. The constraints include:

- Maximum cue volume: 60 dB SPL (software-relative cap, with a calibration step at session start).
- Maximum TMR cues per night: 5.
- Minimum interval between TMR cues: 15 min.
- Maximum hypnopompic wake attempts per night: 2.
- Muse battery < 20%: enter passive recording.
- Muse battery < 10%: save and exit.
- MacBook thermal: extend inference stride from 5s to 15s if sustained high CPU.
- User abort paths: Escape key, voice "stop"/"abort", headband removal.
- Disk space pre-check: ≥ 2 GB free.
- 5-minute disk-buffered segments (at most 5 min data loss on crash).

Each constraint has a code-level enforcement mechanism. The `SafetyEnforcer` is
not a documentation file; it is a class with assertions that are called
before each action.

## The LLM's Role

The LLM does two things:

1. **Generate a primer** (pre-sleep, 2–5 min spoken text). Distills a structured engineering problem into vivid mental imagery. The script is concrete and sensory, not abstract or instructional. The sleeping brain does the synthesis; the LLM provides the imagery.
2. **Analyze the dream report** (post-sleep). Compares the report against the problem context to surface analogies, reframings, and associations. **Does not claim to extract solutions.** Returns structured analysis for the user to evaluate.

Both are one-shot, not real-time. Primer latency target ≤ 30 s. Analysis latency target ≤ 60 s.

The LLM is gated by a content filter. Self-harm, harm-to-others, and medical-advice language are blocked. Filtered analyses are saved with a `contentFilterPassed = false` flag.

## The Experimental Evaluation Plan (D8)

The empirical question — does the full pipeline improve creative problem solving? — is tested through a within-subject crossover study with three conditions (Active / Sham / Control) and N = 30 target enrollment. The full plan, including pre-registration requirements, statistical analysis, and stopping criteria, is in `SLEEP_CYCLE_DESIGN.md` §14 and `docs/Research.md`.

Key constraint: the D8 pre-registration on OSF is **non-negotiable**. Without it, the results are anecdotal.

## Implementation Order

The implementation is sequenced to minimize sophisticated-component work
before EEG acquisition is proven:

**Phase A — Acquisition (DONE)**
1. ✅ Live Muse S acquisition through BrainFlow
2. ✅ Physiological validation (3.08× alpha rise on eyes-closed, 2026-07-10)
3. ✅ Communication-mode architecture complete

**Phase B — Sleep Validation Toolkit (gate before any classifier work)**
4. ✅ EEGScalpPlotterView (3D depth-stacked)
5. ⏳ PSD heatmap
6. ⏳ Alpha/theta ratio tracker
7. ⏳ Blink detector
8. ⏳ Jaw-clench detector
9. ⏳ Electrode-quality monitor
10. ⏳ Line-noise monitor
11. ⏳ Signal-dropout detector

**Phase C — Sleep staging and FSM (D1–D5)**
12–25. EEGWindowingConfig preset, SleepFeatures, SleepStage types, MockSleepStageClassifier, SleepStageSmoother, SleepSessionFSM, TMRBudget, BCIAudio, DreamSessionController, AudioFeedbackProtocol mock, DreamAnalysisPredicting, session wizard UI, recall UI, SessionAnalyzer.

**Phase D — End-to-end validation**
26. First MVP test (30-min nap with known-wake cue at 25 min)
27. Run 3+ MVP sessions of increasing length
28. First 4–5 hour test session

**Phase E — Classifier training and integration**
29. Train Core ML classifier on Sleep-EDFx (offline)
30. Replace MockSleepStageClassifier with CoreMLSleepStageClassifier
31. Add per-user alpha baseline calibration
32. Add TMR cue playback
33. Add hypnopompic wake
34. Add LLM primer generation
35. Add LLM dream analysis
36. Cross-check Python vs Swift streams

**Phase F — D8 pilot feasibility study**
37. Pre-registration on OSF
38. Recruitment and run (N = 30 target, 3 conditions)
39. Analysis and reporting

## Confidence and Uncertainty

Every claim in the system is marked with a confidence rating. The 4-class
classifier is High confidence (matches AASM given the hardware constraint).
The Muse S + BrainFlow pipeline is High confidence (validated). The full
pipeline improving engineering insight is **Low confidence** until D8 runs.
The LLM analogy extraction is **Low confidence** (novel). The classifier
accuracy on Muse S is **Low confidence** (channel mapping is the largest
expected source of error).

The system ships regardless. The platform is useful independently of the empirical questions.

## What to Read Next

- [`SLEEP_CYCLE_DESIGN.md`](../SLEEP_CYCLE_DESIGN.md) — the full type-level specification.
- [`docs/Architecture.md`](Architecture.md) — module structure and isolation discipline.
- [`docs/Math.md`](Math.md) — derivations behind the README equations.
- [`docs/Validation.md`](Validation.md) — the 5-condition protocol and current results.
- [`docs/Research.md`](Research.md) — the D8 pre-registration plan.
