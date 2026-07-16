# Architectural Roadmap

Where the platform grows from here. Distinct from GitHub Issues (which
track discrete tasks): this document tracks *capabilities the
architecture grows toward*, grouped by the layer they extend.

Status icons: `✓` shipped · `□` planned · `~` in progress

---

## Current state

### External Systems
- `✓` Muse S over BrainFlow (native BLE and BLED112 dongle profiles)
- `✓` Muse S Athena (BrainFlow 5.22+, board ID 67)
- `✓` Synthetic EEG (deterministic, for development)
- `✓` CSV playback (regression fixtures)
- `✓` Remote Muse over OSC via Mind Monitor + Tailscale (`b2a6a2f`)

### Runtime
- `✓` Single-owner `EEGStreaming` fan-out via `AsyncMulticastChannel`
- `✓` Channel health provider (per-channel RMS, contact quality, clipping)
- `✓` Golden-recording deterministic playback
- `✓` Stall watchdog in supervisor (5s per-sample timeout, `a0a9e67`)
- `✓` Deployment validation artifacts (`Recordings/deployment/`)

### Intelligence
- `✓` Core ML intent classifier on ANE
- `✓` Band-power feature extraction
- `✓` Random-projection embedding projector (deterministic stub for 3D)
- `~` MLX next-word predictor (BCILLM stub shipped, real model pending)

### Interface
- `✓` SwiftUI app + menu-bar UI
- `✓` 2D depth-stacked EEG plotter
- `✓` 3D SceneKit neural workspace (electrode nodes + edges)
- `✓` Privacy indicator banner
- `✓` Channel-health badge with staleness indicator

---

## Next

Items in priority order. Each builds on a validated foundation from
the layer above. New work goes here when it's ready to spec; the
specific tasks (files, PRs, tests) live in GitHub Issues.

### Runtime
- `□` `StreamDiagnostics` integration with the privacy banner
  (bound port, interface name, heartbeat staleness) — *partially
  shipped in `a4d2ab8`; full UI integration pending*
- `□` Deployment checklist as a runnable validation script
  (currently a markdown document)
- `□` Reconnect-after-interruption integration test (Phase 3.6 follow-up,
  deferred from the OSC review)

### Intelligence
- `✓` `SentenceEmbeding` protocol + stub + tests
- `✓` Core ML MiniLM-L6-v2 adapter (sentence embedder for 3D workspace,
  on ANE)
- `✓` `EmbeddingProjector` integration: `RandomProjectionProjector`
  consumer with real `SentenceEmbeding` input, renderer source-agnostic
- `✓` Stage 3.1–3.3: Individual component validity — EmbeddingBench
  harness, generation benchmark, per-model scientific validation
- `✓` Stage 3.4: Cross-model & cross-runtime **interaction science** —
  complete 2026-07-14 and frozen (`Evaluation/stage_3_4/frozen/`,
  checksummed + read-only). RQ1 runtime equivalence confirmed (4/4
  cross-runtime comparisons at cosine 1.000000), RQ2 geometry / RQ3
  agreement / RQ4 generator comparison evaluated with conditions, RQ5
  joint representations deferred by design; verdicts + evidence map in
  `Evaluation/reports/STAGE_3_4_EXIT_REPORT.md`, analyses in
  `Evaluation/results/stage_3_4/`
- `□` Stage 3.5: Pipeline **system engineering** — policy registry
  (Fast, Balanced, Quality, Adaptive), adaptive routing, cascaded
  generation, confidence-gated selection, pipeline policy comparison;
  results in `Evaluation/results/stage_3_5/`
  - **2026-07-16 decision**: a pasted external proposal asked for a
    production `DynamicRouter`/`CascadeTier` that switches the LLM
    backend/model at runtime based on BCI cognitive-load state. Not
    built: `MLXNextWordPredictor` (`Sources/BCILLM/MLXNextWordPredictor.swift`)
    is an actor holding one `ModelContainer` set once at init, and its
    own doc comment warns that two resident models thrash the GPU;
    `PredictorFactory.live()` resolves one backend behind a 20s
    crash-safety probe, not something to repeat per request. Real
    tier-switching is exactly this Stage 3.5 policy-registry work and
    stays gated behind it — see `3.5-D-cascaded-generation` in
    `Evaluation/corpora/hypothesis_registry.json`, still
    `"pre-registered"`. `GenerationAdaptation`
    (`Sources/BCICore/Composition/GenerationAdaptation.swift`, shipped
    2026-07-16) — candidate count/temperature/prompt-style, applied to
    the single resolved predictor — is the production adaptation
    mechanism until this stage produces evidence for anything more.
- `□` Stage 4: Deploy only what the evidence supports — adaptive
  routing, learned confidence estimation, online policy selection,
  production telemetry (privacy-preserving), continual evaluation.
  Stage 4 **consumes** evidence, not generates it.
  - Note: this "production telemetry" is about instrumenting the
    *routing/policy system* once Stage 3.5 has evidence to act on — a
    different, narrower thing than the opt-in local interaction logger
    landing alongside this note (`ADR-005-local-interaction-logging.md`),
    which captures raw (state, commit) pairs for possible future
    training data and doesn't inform any routing decision.

### Interface
- `□` Playback-driven 2D + 3D visualization (the canonical demo path;
  validates the Intelligence layer without live hardware)
- `□` Classifier confidence visualization over deterministic playback
  (proves the classifier composes correctly with the rest of the
  pipeline)

### Cross-cutting
- `□` Initial ADR set in `docs/architecture/decision-log/`
  (ADR-001 through ADR-004 cover the major decisions made to date)
- `□` `docs/architecture/PRINCIPLES.md` — engineering values that
  govern how new work is integrated
- `□` Layered architecture diagram in the main README

---

## Future

Capabilities the architecture is designed to support, but which are
not yet on the active development path. These belong here, not in
"Next," because the prerequisites (protocols, fixtures, deployment
validation) are still landing.

### Intelligence
- `□` Online adaptation: classifier that updates to a specific user
  over a calibration session, without losing the cross-user baseline
- `□` Cross-modal embeddings: combine EEG-derived features with
  external context (task description, prior session history) for
  richer semantic visualization
- `□` Multi-user collaboration: shared 3D workspace across multiple
  NeuralCompose instances, each running on its own Muse

### Interface
- `□` Local web dashboard for remote monitoring (deferred from the
  Phase 3.6 OSC review; the underlying `StreamDiagnostics` work is
  shipped, the HTTP layer is not)
- `□` LLM-assisted communication: the existing `BCILLM` slot
  populated with a real generative model, with the carousel UX
  refactored to consume it (currently stubbed)

### External Systems
- `□` Additional Muse profiles as BrainFlow adds them
- `□` Non-Muse EEG sources (OpenBCI, g.tec) via the same
  `EEGStreaming` protocol — the layer rename to *External Systems*
  is forward-compatible with this
- `□` Simulated streams for synthetic-bench experiments (the current
  `SyntheticEEGStream` is a development convenience; a separate
  *benchmark* stream with controlled noise models is a different
  capability)
