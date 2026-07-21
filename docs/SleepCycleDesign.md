# Sleep Cycle Design (Reader-Friendly Summary)

The full D1–D8 specification is at [`SLEEP_CYCLE_DESIGN.md`](../SLEEP_CYCLE_DESIGN.md) at the repo root. That document is the canonical type-level design — long, technical, and load-bearing for implementation. This document is the reader-friendly summary: it explains the design decisions, the open questions, and the implementation order, without reproducing the type signatures.

**D1–D8 legend** (the eight design modules, `SLEEP_CYCLE_DESIGN.md` §7–§14): **D1** sleep-stage model · **D2** staging protocol + Core ML classifier · **D3** stage smoother · **D4** sleep-session FSM · **D5** dream-session controller · **D6** dream-analysis LLM · **D7** post-sleep analysis · **D8** experimental evaluation study — the pilot human trial (see [`Research.md`](Research.md)). "D" is a **design-deliverable** index — *not* a hardware channel count, a cursor-direction (8-way) algorithm, or a downsample-by-8 factor.

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
| 2 | 3D live neural workspace | SceneKit topography of 4 electrodes, alpha→emissive, theta→elevation, FSM→color | "Is the signal behaving as expected across channels?" |
| 3 | PSD heatmap | Per-channel spectrogram 0.5–40 Hz | "Are we seeing alpha in eyes-closed?" |
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
5. ✅ NeuralWorkspaceView (SceneKit 3D live topography)
6. ⏳ PSD heatmap
7. ⏳ Alpha/theta ratio tracker
8. ⏳ Blink detector
9. ⏳ Jaw-clench detector
10. ⏳ Electrode-quality monitor
11. ⏳ Line-noise monitor
12. ⏳ Signal-dropout detector

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

---

## Dream-Mode Design Audit (2026-07-19, paste-as-wrapper)

A second design input landed in this repo on 2026-07-19: a paste containing
(a) a `hypothesis_registry.json` schema with **routing** (primary_anchors /
semantic_domain / drift_tolerance), **cascades** (on_drift_timeout /
on_arousal / on_lucidity_detected), and **policies** (intervention_intensity
/ require_debounce / allowed_tones), plus a global_policies block; (b) a
Python `DreamExtractionPipeline` (denoise + symbol ID + analogical mapping
against a hypothesis); (c) a `HypothesisRegistry` config-manager class; (d)
a refactored `DreamSessionFSM` that reads cooldowns and intervention limits
from the JSON; (e) a `Codable` Swift schema for the same JSON; (f) a Swift
`actor DreamSessionFSM`; and (g) a Random Forest sleep-stage classifier
sketch (4-class, relative band power, exports to CoreML).

This section records the review of that paste against the canonical D1–D8
design above. The paste is integrated as a design input per the paste-driven
rule (the paste IS the design; integrate verbatim, don't re-litigate settled
points). The Stage 3.4/3.5/4 boundary contract is treated as active by
default — see `Evaluation/reports/decision_registry.md` entry 7.

### What the paste integrates cleanly

- The **routing/cascades/policies** schema is a useful enrichment of the
  existing Hypothesis Registry conventions. It extends the schema with three
  optional fields per hypothesis; the existing 3.4-A through 3.5-P entries
  are unaffected. See `Evaluation/corpora/dream_mode_hypothesis_registry.json`
  (extracted 2026-07-19 to keep the Stage 3.4/3.5 baseline immutable);
  hypotheses S-1 through S-4, plus an `example_hypotheses_for_schema_validation`
  block with the two pasted examples (hyp_fear_failure_01,
  hyp_safe_exploration_01) for shape validation.
- The **Python offline extraction + drift scoring** shape is the right MVP
  for the offline tier (S-2). It will require a human-rated baseline before
  drift can be used as a cascade trigger — LLM self-evaluated drift is a
  known weak point for models under 30B and must be validated.
- The **Random Forest sleep-stage classifier** sketch (S-3) is fine for a
  pipeline-extraction test on synthetic data. No labeled sleep-staging
  dataset exists in the repo; `Recordings/` contains Muse validation
  recordings and one calibration labels file, not PSG.
- The **Swift `actor DreamSessionFSM`** shape (S-4) is the right foundation
  for Stage 4. Concrete type to delegate to is `AVSpeechSynthesizerService`
  in `Sources/BCIVoice/`, not a fabricated `HypnosisSynthesizer` singleton.
  The cascade handlers map cleanly to the schema's `on_arousal`,
  `on_drift_timeout`, `on_lucidity_detected` keys.

### What the paste gets wrong against the actual repo

- **"iOS app / CoreBluetooth delegate queue / iOS bundle"** — wrong target.
  This is a macOS app. The EEG stream comes from BrainFlow, not
  CoreBluetooth. `Sources/NeuralComposeApp` is an executable target
  (`Package.swift` line 137), not an iOS bundle. AVFoundation's
  `AVSpeechSynthesizer` works on both, but the framing should be macOS.
- **"`HypnosisSynthesizer` actor we built previously"** — fabricated prior
  art. The real TTS path is `Sources/BCIVoice/AVSpeechSynthesizerService.swift`
  (an `actor SpeechSynthesizing` conforming type using AVFoundation, with
  `speak(_:) async throws` and `stopSpeaking() async`). No such
  `HypnosisSynthesizer` exists in this repo.
- **The Swift actor's `cascade(to:)` method** has a real Swift-concurrency
  bug if ported verbatim: `var updatedFSM = self; _ = updatedFSM.loadHypothesis(...);
  self.activeHypothesisID = updatedFSM.activeHypothesisID; ...` is a
  no-op pattern on actor stored properties. Stage 4 implementation must
  inline mutation in the actor's isolated body, not copy-and-reassign.
- **"CoreML for Stage 4 iOS integration"** in the Random Forest sketch —
  should read "CoreML for the macOS deployment path matching
  `BCIClassifier`'s existing ANE-preferred CoreML wrapper" (see
  `Sources/BCIClassifier/`).
- **"Why Random Forest over Deep Learning"** rationale — opinionated, not
  evidence-based. Conflates JEPA (a `WorldModel/` research spike, decoupled
  per `CLAUDE.md`) with the EEG pipeline. Remove from the final schema doc.
- **The `hypothesis_registry.json` filename** in the paste is the same
  filename as the existing Stage 3.4/3.5 hypothesis registry at
  `Evaluation/corpora/hypothesis_registry.json`. The two artifacts have
  different schemas and different governance roles. The dream-mode
  hypotheses were initially inlined as a `stage_4_sleep_dream_mode` block
  in the existing file, then **extracted 2026-07-19** to
  `Evaluation/corpora/dream_mode_hypothesis_registry.json` to keep the
  Stage 3.4/3.5 evaluation baseline immutable. The two registries are
  now decoupled at the filesystem level.

### Schema extension conventions

When a new design input extends the Hypothesis Registry, the convention is
to add a new top-level key (e.g. `stage_4_sleep_dream_mode`) with a
`_meta` block (version, source inputs, boundary contract, llm candidate,
tts path, model note) and a `hypotheses` array following the existing
schema (id, title, question, metric, success_criterion, expected_effect_size,
status, status_note). Pre-registration of design inputs is a schema review,
not an evidence gate; status_note records what was reviewed and what is
unproven.

### Repo target map (when Stage 4 opens)

| Paste component | Repo target | Tier |
|---|---|---|
| `SymbolicCache` SQLite schema | `Scripts/dream_extraction.py` (creates `data/symbolic_cache.db`) | Offline |
| `DreamExtractionPipeline` | `Scripts/dream_extraction.py` (model-agnostic, qwen2.5-0.5b candidate) | Offline |
| `HypothesisRegistry` config manager | `Scripts/hypothesis_registry.py` (thin wrapper around the JSON) | Offline |
| `PrimerGenerator` | `Scripts/primer_generator.py` (bakes audio fixtures for `BCIVoice` to load) | Offline |
| `DreamSessionFSM` (Python) | `Sources/BCICore/Sleep/SleepSessionFSM.swift` (D4) | Production, Swift |
| Python `DreamSessionFSM` (replay) | `Scripts/dream_session_replay.py` (consumes recorded EEG CSV + Swift FSM output, reports divergence) | Offline |
| `subprocess.Popen(['say'])` | `Sources/BCIVoice/AVSpeechSynthesizerService.speak(_:)` (D5, D6a) | Production, Swift |
| Hypothesis Registry (governance) | `Evaluation/corpora/dream_mode_hypothesis_registry.json` (extracted, single source of truth) | Governance |
| Risk Register | Already in `SLEEP_CYCLE_DESIGN.md` §6 (full 10-row table) | Governance |
| Safety requirements | Already in `SLEEP_CYCLE_DESIGN.md` §6a (audio, sleep, hardware, user) | Governance |
| Pilot feasibility study | `docs/Research.md` D8 plan (N=30, OSF pre-registration, Bayes factors) | Governance + design |
