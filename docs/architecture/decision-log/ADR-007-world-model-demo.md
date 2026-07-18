# ADR-007: World Model MPC demo is an off-by-default, synthetic-task-only research window

**Status**: Accepted
**Date**: 2026-07-18

## Context

`ADR-006` created a data-collection path for a real-EEG JEPA but explicitly
left "loading a JEPA checkpoint in the app... MPC, latent anchoring, or any
automatic generation adaptation based on this data set" undecided.
`WorldModel/EEG_INTEGRATION_DESIGN.md` separately rejected, unconditionally,
a proposal to wire this spike into production via a cloud LLM and an invented
UI action space.

This session did the next real step in the spike itself: fixed a diagnosed
statistical pathology in the synthetic-task MPC planner (`WorldModel/mpc.py`,
see `WorldModel/README.md`'s "Temperature/cost-scale calibration" section),
exported that (still synthetic-task-only) JEPA to Core ML
(`WorldModel/export_coreml.py`), and ported the MPPI planner to Swift
(`Sources/WorldModelDemo/`) to prove the whole toolchain runs natively on the
ANE. None of this touches real EEG data, and none of it is a decision to
promote the spike past what `ADR-006`/`EEG_INTEGRATION_DESIGN.md` already
declined to decide.

## Decision

Add a separate, visibly-labeled research demo with its own consent boundary,
distinct from every existing opt-in toggle:

- `Sources/WorldModelDemo/` is a new SwiftPM library target, depending only on
  `BCICore` — no MLX, no new third-party dependency, imported only by
  `NeuralComposeApp`. It is deliberately not `BCI*`-prefixed: every `BCI*`
  target is a real production-pipeline stage, and this is a synthetic-task
  research demo, mirroring `WorldModel/README.md`'s own decoupling stance.
- The demo runs entirely on a self-contained, in-process 2D particle-navigation
  simulation (`ParticleNavigatorEnv`, a direct Swift port of `env.py`). It
  never reads `EEGWindow`, `SpectralState`, or `JEPASpectralState`, and never
  touches `TextCompositionController` or the real carousel/typing path.
- `AppViewModel.worldModelDemoEnabled` defaults to `false`, independent of
  `interactionLoggingEnabled` and `jepaTransitionCaptureEnabled`. Unlike those
  two toggles, this one gates no data persistence at all — the demo writes
  nothing to disk in either state, so its privacy-panel copy describes
  reachability ("demo window is idle") rather than a file path.
- The privacy panel shows a distinct, always-visible red "World Model Demo"
  badge while active (`cube.transparent`), following the same "obvious while
  recording/running" convention as the interaction-log and JEPA-capture
  badges, even though nothing here is actually recorded.
- The demo window itself (`WorldModelMPCDemoView`) is reachable only through
  its own `Window` scene (`AppCommand.openWorldModelDemo`), never embedded in
  `ContentView`'s body — structurally unreachable from the real typing path.
- An "illustrative generation" panel maps the planner's own effective-sample-size
  ratio through a hand-picked function onto `GenerationAdaptation`
  (`maxCandidates`/`temperature` — the one real action surface this app has,
  per `EEG_INTEGRATION_DESIGN.md`'s Phase 3 correction) and calls the real,
  on-device `MLXNextWordPredictor`. This proves the on-device, zero-network
  loop closes end to end; it is captioned, prominently and permanently
  (`WorldModelDemoHonesty.illustrativeMappingCaveat`), as a hand-picked
  mapping, not a trained or validated connection between the synthetic task
  and real generation quality.
- Falls back to `BaselineWorldModelDemoPlanner` (a simple proportional
  controller, no CoreML, no learned weights) whenever
  `Models/WorldModelDemo/`'s three exported `.mlpackage`s are absent or fail
  to load — same stub-by-default shape as every other model-backed subsystem
  in this app.

## Consequences

The demo proves the CoreML/ANE export-and-inference toolchain works, and that
a Swift-native MPPI port produces sane trajectories on the toy task it was
built for. It changes nothing about the real pipeline's behavior, defaults,
or data footprint. It is not evidence that this architecture is ready for real
EEG data — the encoder here was never trained on EEG, there is still no
validated real-EEG corpus (`ADR-006`), and `EEG_INTEGRATION_DESIGN.md`'s
Phase 2/4 prerequisites (a separately-validated continuous encoder; a pinned
validation threshold before anchoring automatic behavior to an unvalidated
latent space) remain entirely unmet.

## Explicitly not decided here

- pointing any part of this Swift pipeline at real EEG data or a real
  `SpectralEncoderModel`/`eeg_jepa.py` checkpoint;
- promoting the illustrative `GenerationAdaptation` mapping into a real,
  trained, or user-facing generation-adaptation path;
- changing `interactionLoggingEnabled`'s or `jepaTransitionCaptureEnabled`'s
  existing opt-in defaults or contracts;
- the no-network-at-runtime rule, or any cloud LLM integration.
