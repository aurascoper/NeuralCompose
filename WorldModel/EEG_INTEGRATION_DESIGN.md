# EEG Integration Design Notes (speculative, not scheduled)

**Status: design doc only.** Nothing here is built, nothing here is scheduled. No code in `Sources/` changes as a result of this document, no new runtime process gets added, and nothing here should be read as committing NeuralCompose to this path — that's a future decision, contingent on real prerequisites (below) actually existing, exactly as `WorldModel/README.md`'s own "Why synthetic, and why decoupled from EEG" section already frames the whole spike.

This document exists because a real-EEG-integration proposal was raised for the WorldModel JEPA+MPC spike, alongside a full Swift+Python+ZeroMQ deployment architecture and cloud LLM calls. Rather than accept that proposal's premises, this doc checks them against the actual codebase and corrects them where they're wrong — in several places the real infrastructure is *both less and more* than the proposal assumed: less, because no paired interaction dataset exists to train anything on; more, because a real continuous EEG-window encoder and a real sliding-window pipeline already ship, which the proposal didn't know about.

## What's explicitly rejected, not just deferred

Get these out of the way first, because they don't depend on how the rest of this plays out:

- **A separate Python backend process bridged to Swift via ZeroMQ.** `CLAUDE.md` is explicit: MLX is linked *only* into `BCILLM`, as a single runtime in the app's own binary — that design specifically avoids needing a second process. A dual-process IPC architecture is a different app architecture, not an extension of this one. If that trade-off is ever worth revisiting, it's its own conversation with its own trade-off analysis — not something to fold into a research-spike design doc.
- **Cloud LLM API calls (OpenAI/Anthropic).** `CLAUDE.md`: *"No network at runtime. No cloud. No telemetry."* This isn't a "not yet" — any real-time constraint injection this work ever produces has to go through the existing local MLX path (`Sources/BCILLM/MLXNextWordPredictor.swift`, `GenerationAdaptation`), full stop.
- **The literal `<50ms` latency budget.** That number wasn't derived from anything about this app's real deployment target — it came from a different, unbuilt system's proposal. `WorldModel/mpc.py`/`telemetry.py` already measure planning latency honestly (5-12ms range on the synthetic task) without asserting a budget; if real-time constraints ever matter here, they need to be re-derived against whatever the real encoder/predictor/target actually turn out to be, not assumed in advance.

## Phase 1 — Data ingestion: less missing than assumed, and what's missing is more specific

The original proposal assumed a sliding-window `Dataset` needed to be built from scratch, ingesting "power spectral density across standard frequency bands... over `C` channels" into `(Channels, Time)` tensors, and cited "8 channels × 5 bands = 40 features."

**That's wrong on two counts, and the correction matters:**

1. **A real sliding-window pipeline already ships.** `Sources/BCICore/Preprocessing/EEGWindowing.swift` (`EEGWindowing`, an actor) and `Sources/BCICore/Models/EEGWindow.swift` (`EEGWindow`) already do exactly this: `EEGWindowingConfig` defaults to 4 channels, 2.0-second windows at 256 Hz, 50% overlap (1-second stride) — `EEGWindow.samples: [[Float]]` is channel-major, exactly the `(Channels, Time)` shape the proposal wanted, i.e. `(4, 512)` per window at the defaults.
2. **The real montage is 4 channels, not 8, and the real encoder (Phase 2) consumes raw waveform samples, not hand-computed band powers.** `EEGWindowingConfig.channelCount` defaults to 4, matching the real Muse TP9/AF7/AF8/TP10 hardware (see `CLAUDE.md`'s Track B section). Nothing in this pipeline pre-computes PSD band ratios into a 40-dim feature vector before windowing — that "40 features" framing doesn't correspond to anything real here.

**What's actually missing** is narrower than "build a windower": nothing **persists** `(window, action, next_window)` tuples to disk in a form an offline PyTorch trainer could load. `EEGWindowing` produces windows live, in-memory, for immediate classification — it was never meant to be a training-data logger.

**And the gap is more than absence — it's a documented, deliberate design decision.** `Sources/BCICore/Telemetry/TelemetryEvent.swift`'s own doc comment: *"Deliberately omits the raw continuous spectral embedding — `detectedSpectralState` is the classified anchor label, and logging more than that would imply a precision `SpectralState.honestyCaveat` explicitly disclaims."* `TelemetryEvent` already exists, is already opt-in interaction logging (per `ADR-005-local-interaction-logging.md`), and was *specifically designed not to capture* the kind of continuous signal a JEPA training pipeline would need. Building that pipeline isn't "flip a switch on existing logging" — it's revisiting a principled decision that's already been made and documented, which deserves its own explicit conversation, not a silent reversal buried inside a bigger integration.

## Phase 2 — Encoder: a real one already exists, but it was trained for a different job

The original proposal designed a from-scratch `EEGSpatialTemporalEncoder` (Conv1d → GroupNorm → GELU, `AdaptiveAvgPool1d` for window-length invariance, projected to a 32-dim latent) to replace Day 2's MLP `Encoder`.

**Correction: a real, trained, shipping continuous EEG-window encoder already exists.** `SpectralEncoderModel` (`Sources/BCILLM/`, loaded by `SpectralStateEstimator.swift` from `Models/EEGEncoder/*.safetensors`, configured via `SpectralEncoderConfig`) consumes raw waveform input shaped `[1, windowSamples, inChannels]` (channels-last — a transpose away from `EEGWindow`'s channel-major layout, nothing structural) and produces a continuous `outDim`-dimensional embedding — confirmed by direct read of `SpectralStateEstimator.estimate(window:)`, which builds exactly this tensor and calls `model(input)`.

**But its embedding space was trained for classification-by-nearest-text-anchor, not latent dynamics prediction.** `SpectralStateEstimator`'s constructor re-encodes `SpectralState`'s five `descriptor` phrases through the app's live BGE `SentenceEmbedder`, then classifies each EEG window by cosine similarity against those five anchor vectors. So `SpectralEncoderModel`'s output space is whatever was needed to align with a BGE *text*-sentence-embedding space for that classification task — a completely different training objective and geometry than "predict this window's latent from the previous window's latent and an action," which is what a JEPA predictor needs.

**Reusing this exact model is tempting (same raw-window input contract) but has a real failure mode worth naming.** `SpectralStateEstimator`'s constructor has an honesty gate: it refuses to load unless the checkpoint's own provenance stamp confirms `target_space` starts with `"bge:"` **and** the live embedder is actually real BGE (not the deterministic stub). Fine-tuning `SpectralEncoderModel`'s weights under a VICReg+prediction objective would almost certainly destroy that BGE-alignment property as a side effect — and if a JEPA-tuned checkpoint ever got loaded into the classification path by mistake (shared filename, shared directory, a careless copy), that honesty gate is exactly the kind of check that could either wrongly refuse a still-valid checkpoint or — worse — wrongly accept a corrupted one if the provenance stamp isn't regenerated correctly.

**Recommendation: a separate, freshly-initialized encoder for the JEPA path**, structurally similar to what the original proposal designed (Conv1d/GroupNorm is sound, and consistent with Day 2's own reasoning for LayerNorm-not-BatchNorm — i.i.d.-shuffled transitions leak batch statistics; GroupNorm's per-sample-per-group normalization has the same property) — but never sharing weights or files with `SpectralEncoderModel`. This directly mirrors the "architecture isolation rule" `CLAUDE.md` already mandates for Track B: imagined-speech labels/classifier/trainer kept parallel to Track A's, never extensions, specifically so a training run against one never corrupts the other.

## Phase 3 — Action space: use what's real, not what's imagined

The original proposal invented a 6-dimensional LLM/UI action space: verbosity, syntactic complexity, formatting density, modality (visual/audio), UI density, and predictive-text aggressiveness.

**None of these exist as real levers in the app today**, confirmed by direct code search: no UI-density concept anywhere, no automatic (non-user-triggered) modality switching (TTS and dictation both require an explicit button press today), no "formatting density" control, no continuous verbosity dial.

**The one real, existing "action" surface is `GenerationAdaptation`** (`Sources/BCICore/Composition/GenerationAdaptation.swift`): exactly three fields — `maxCandidates: Int`, `temperature: Double`, `styleInstruction: String` — computed today by a static, conservative, narrows-only rule table (`SpectralGenerationRules.swift`) keyed off the discrete `SpectralState`. If a JEPA action vector is ever built for real, it should be derived from *this* surface — e.g. normalized `maxCandidates`/`temperature` as two continuous dimensions, `styleInstruction` reduced to a small discrete category — not from invented UI axes with no corresponding app behavior. Expanding `GenerationAdaptation` itself (adding a UI-density field, say) would be new app feature work in its own right, prior to and independent of anything JEPA-related.

## Phase 4 — Calibration/anchoring: the idea is sound, the prerequisites and stakes aren't small

The centroid-capture idea — record a known-state session (flow, fatigue), pass it through the frozen encoder, take the mean latent vector as an anchor for the MPC cost function — is methodologically reasonable and is a standard technique. It's included here for completeness, not because it's wrong on its own terms.

**But it has two real prerequisites, neither of which exist yet**: Phase 1 (a persisted, offline-loadable dataset) and Phase 2 (a trained continuous encoder for the JEPA path specifically). Calibration can't happen before both of those do.

**It also raises a real stakes question worth stating plainly rather than deferring past.** `SpectralState` ships today with an explicit, deliberately-attached caveat: *"Heuristic gloss over this window's own power-spectral ratios — not a validated cognitive-state read."* That caveat exists precisely because a 5-way discrete classification is being used to *inform* generation parameters, conservatively, narrows-only, with the detection always visible in the UI badge regardless of whether adaptation is enabled. Anchoring an MPC's automatic steering decisions to centroids in an *unvalidated continuous* latent space is a materially larger trust claim, on a *less* interpretable signal, driving *bidirectional* (not narrows-only) automatic behavior change. If this is ever pursued, it deserves the same treatment `CLAUDE.md` already mandates for Track B: a validation threshold — e.g., held-out balanced accuracy distinguishing self-reported flow vs. fatigue sessions — pinned *before* building anything on top of it, not promoted on "looks promising" once training loss goes down.

## A speculative future optimization, noted for completeness

If a real encoder/predictor/MPC stack is ever built and deployed, and the sampling-based MPPI planning step turns out to be too slow or battery-hungry for continuous on-device use, **policy distillation** (train a small feedforward "actor" network offline to imitate the MPPI planner's outputs, then run just that small network at inference time — potentially via Core ML on the ANE) is a standard, legitimate technique worth remembering. Not scoped now; noted here so it isn't lost.

## Summary table

| Proposal component | Status |
|---|---|
| Sliding-window `(Channels, Time)` ingestion | **Windowing infra already real** (`EEGWindowing`/`EEGWindow`, 4ch/2s/256Hz). Persisted `(window, action, next_window)` dataset is the actual gap — and `TelemetryEvent` was deliberately designed not to capture this. |
| Continuous EEG-window encoder | **A real one already ships** (`SpectralEncoderModel`), but trained for BGE-text-anchor classification, not latent dynamics. A separate encoder is needed for the JEPA path — reuse the input contract, not the weights. |
| 6-axis LLM/UI action space | **Doesn't exist.** The only real lever is `GenerationAdaptation`'s 3 fields, computed today by a static rule table. |
| Flow/fatigue latent anchoring | Sound idea, blocked on Phases 1-2, and raises a real validation-before-trust question `SpectralState`'s own honesty caveat already anticipates. |
| Swift+Python+ZeroMQ dual process | **Rejected.** Contradicts the documented single-MLX-in-`BCILLM` architecture. |
| Cloud LLM API calls | **Rejected, unconditionally.** Conflicts with "No network at runtime. No cloud." |
| `<50ms` latency budget | **Not adopted as a target.** Not derived from this app's real deployment target; measure honestly instead, as `mpc.py`/`telemetry.py` already do. |
| ANE policy distillation | Legitimate, standard future optimization — noted, not scoped. |
