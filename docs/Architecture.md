# Architecture

This document describes the module structure, design rationale, and the
isolation discipline that keeps the platform shippable as research software.
For the full type-level specification of the sleep-cycle mode, see
[`SLEEP_CYCLE_DESIGN.md`](../SLEEP_CYCLE_DESIGN.md) at the repo root.

## Module Structure

```
                    ┌──────────────────────────────────────────────────────┐
                    │                NeuralComposeApp                       │
                    │  (SwiftUI: comms window, Phase B debug, menu-bar UI)  │
                    └─────┬──────────────────────────┬──────────────────────┘
                          │                          │
                          ▼                          ▼
                ┌──────────────────┐        ┌─────────────────────────┐
                │ TextComposition  │        │  SleepValidationView    │
                │ Controller       │        │  (Phase B debug)        │
                └────────┬─────────┘        └─────────────────────────┘
                         │
                         ▼
                ┌──────────────────┐    ┌──────────────────┐    ┌──────────────────┐
                │ IntentSmoother   │    │ SleepStageSmoother│    │ DreamAnalysis    │
                │ (BCICore actor)  │    │ (BCICore actor)  │    │ Predicting (LLM) │
                └────────┬─────────┘    └────────┬─────────┘    └────────┬─────────┘
                         ▼                       ▼                       ▼
                ┌──────────────────┐    ┌──────────────────┐    ┌──────────────────┐
                │ IntentState      │    │ SleepSessionFSM  │    │  MLX adapter     │
                │ Machine          │    │                  │    │  (BCILLM)        │
                └──────────────────┘    └──────────────────┘    └──────────────────┘
```

### Module Ownership

| Target | Contains | Third-party deps |
|--------|----------|------------------|
| `BCIBridge` | Obj-C++ shim for BrainFlow C API. Stub by default; real BrainFlow gated by `BCI_BRAINFLOW_AVAILABLE`. | None (header-only C interface; `.dylib` resolved at runtime) |
| `BCICore` | All pure-Swift models, protocols, FSMs, ring buffers, validation types. **No third-party deps.** | None |
| `BCIEEG` | `BrainFlowService` (live), `SyntheticEEGStream` (mock), `PlaybackEEGStream` (CSV replay), `EEGScalpPlotterView` (Phase B), `EEGStreamFactory`, `CalibrationRecorder`. | AppKit + QuartzCore (for the plotter). No third-party deps. |
| `BCIClassifier` | `CoreMLIntentClassifier`, `MockIntentClassifier`, `ClassifierFactory`. | Core ML (Apple framework) |
| `BCILLM` | `MLXNextWordPredictor`, `StubNextWordPredictor`, `PredictorFactory`, `TokenizerService`. | **MLX-Swift**, mlx-swift-examples, swift-transformers. **Linked only into this target.** |
| `NeuralComposeApp` | SwiftUI views, `AppViewModel`, `AppContainer`, the Phase B debug window, the menu-bar UI. | Depends on all of the above. |

### MLX Isolation Discipline

The pattern is:

1. The app target talks to `BCILLM` through the `NextWordPredicting` protocol defined in `BCICore`.
2. The protocol has no MLX import.
3. `BCILLM` is the only target that links `mlx-swift`, `mlx-swift-examples`, or `swift-transformers`.
4. The app target never imports `MLX` or `swift-transformers` directly.

The result: there is exactly **one** MLX runtime copy in the linked binary, no duplicate-symbol risk, and the app could in principle swap `BCILLM` for a different LLM adapter without recompiling the UI. New LLM-related code (the `DreamAnalysisPredicting` implementation, primer generation templates) lives in `BCILLM` for the same reason.

### BrainFlow Isolation

BrainFlow is **not** a SwiftPM dependency. It is an optional system library surfaced through the `BCIBridge` Obj-C++ shim and gated by the `BCI_BRAINFLOW_AVAILABLE` compile flag.

The `BCIBridge` target exposes a small C interface (e.g. `bci_bridge_create_session`, `bci_bridge_drain_samples`, `bci_bridge_sample_rate`, `bci_bridge_board_id_muse_s`). The Swift side talks only to this interface. Without `BCI_BRAINFLOW_AVAILABLE=1` at build time, the shim compiles in stub mode and the EEG stream factory falls back to `SyntheticEEGStream`.

This means:

- `swift build` works out of the box without BrainFlow installed.
- `./Scripts/build.sh --with-brainflow` activates the real path.
- A nightly or CI build can verify the stub path stays compilable.

## Data Flow: Communication Mode

```
 Muse S ── BLE ──▶ Core Bluetooth ──▶ BrainFlow dylib ──▶ BCIBridge
                                                              │
                                                              ▼
                                                  BrainFlowService (actor)
                                                              │
                                                              ▼
                                                    EEGStream (AsyncThrowingStream<EEGSample>)
                                                              │
                                                              ▼
                                                    EEGWindowing (actor)
                                                              │
                                                              ▼
                                                    IntentClassifying
                                                              │
                                                              ▼
                                                    IntentSmoother
                                                              │
                                                              ▼
                                                    IntentStateMachine
                                                              │
                                                              ▼ (select event)
                                                    TextCompositionController
                                                              │
                                                              ▼
                                                    MLX LLM next-word
                                                              │
                                                              ▼
                                                    Carousel
```

## Data Flow: Sleep Validation Toolkit (Phase B)

```
 Muse S ── BLE ──▶ BrainFlowService (or SyntheticEEGStream)
                                  │
                                  ▼
                       EEGScalpPlotterView
                       (60 Hz display link,
                        3D depth-stacked CAShapeLayers)
```

Phase B is intentionally minimal. The next components (PSD heatmap, blink detector, jaw-clench detector, electrode-quality monitor, line-noise monitor, signal-dropout detector) consume the same `EEGStream` and produce `BoundedAsyncChannel<ToolkitEvent>` outputs that the debug view subscribes to. The full toolkit is in §21 of `SLEEP_CYCLE_DESIGN.md`.

## Concurrency Discipline

Swift 6 strict concurrency throughout. All shared state is in actors or value types. No global mutable state.

- `BCIBridge` is a stateless C interface.
- `BrainFlowService` is `@unchecked Sendable` because it holds a C handle; the Swift side never touches the handle outside actor-isolated methods.
- `EEGWindowing`, `IntentSmoother`, `SleepStageSmoother`, `TextCompositionController`, `DreamSessionController` are all actors.
- `IntentStateMachine` and `SleepSessionFSM` are value types with pure-function `step(_:current:)` transitions.
- `EEGSample`, `EEGSample`, `EEGSample`, `SleepStage`, `SleepStagePrediction`, `DreamAnalysis`, `SleepSessionRecord` are all `Sendable` value types.

## Why This Architecture

A few design choices deserve a defense:

**Why actors for buffers and smoothers, not locks.** Actors compose better with `AsyncSequence` consumers. The SwiftUI view subscribes to a `BoundedAsyncChannel<ToolkitEvent>` and the channel hands off the event-isolation boundary for free.

**Why value types for state machines.** State machines are pure functions. Making them value types means they can be tested without an actor runtime, snapshotted, and restored. The actor layer above them owns the mutable state.

**Why a separate `BCIBridge` shim instead of linking BrainFlow directly.** Three reasons: (a) the rest of the codebase stays unaware of BrainFlow, so a future BCI library can be swapped in; (b) the stub mode makes `swift build` work on developer machines without BrainFlow installed; (c) the C interface is the *testable* surface — Python, Swift, and tests can all exercise the same shim.

**Why the validation toolkit is a separate window (`Cmd+Shift+D`).** The toolkit is a developer tool, not a user feature. Hiding it behind a keyboard shortcut keeps the comms-mode UI clean while making the toolkit available when needed.
