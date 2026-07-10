# ADR-003: Runtime separation — Core ML on ANE, MLX isolated to BCILLM

**Status**: Accepted
**Date**: 2026-07-10

## Context

NeuralCompose runs two different kinds of model inference on Apple
Silicon:

- **Deterministic inference**: the intent classifier, the (future)
  MiniLM sentence embedder. These run on the Apple Neural Engine via
  Core ML. They are fast, deterministic, and need to coexist with the
  real-time EEG pipeline.
- **Generative inference**: the next-word predictor. This runs via
  MLX on the GPU/CPU. It is large, slower, and runs only when
  triggered by user intent (carousel commit).

These two runtimes have different lifecycle requirements, different
deployment shapes (the Core ML model is a few-hundred-MB `.mlpackage`;
the MLX model is a multi-GB safetensors directory), and different
failure modes (Core ML's ANE has fixed input shapes; MLX's GPU
allocator has its own OOM behavior). They must not be linked into the
same SwiftPM target: doing so duplicates the runtime, creates symbol
collisions, and couples their version-update cycles.

## Decision

Core ML is the runtime for deterministic inference (classifier,
embedder). MLX is the runtime for generative inference (next-word
predictor). They live in different SwiftPM targets:

- `BCIClassifier` imports Core ML (`CoreMLIntentClassifier`, future
  `CoreMLSentenceEmbedder`)
- `BCILLM` imports MLX (`MLXNextWordPredictor`, tokenizer utilities)
- `BCICore` and `BCIEEG` import neither
- `NeuralComposeApp` consumes both through their public protocols
  (`IntentClassifying`, `NextWordPredicting`, future
  `SentenceEmbedding`) — never through a concrete type

The rule is enforced by the dependency graph in `Package.swift`:
`BCILLM` is the only target that depends on `mlx-swift` and
`mlx-swift-examples`; `BCIClassifier` is the only target that depends
on `CoreML`. A new dependency on either must justify why it belongs
in the same target as the existing consumer.

## Alternatives Considered

**Both runtimes in `BCICore`.** Simpler dependency graph, but
duplicates the MLX runtime symbols if the app target ever needs both,
and makes every consumer of `BCICore` pay the cost of linking both
runtimes. Rejected.

**A new `BCIInference` target that wraps both.** Solves the symbol
duplication, but creates a target whose responsibility is "wrap a
runtime," which is the wrong abstraction — the right abstraction is
the *task* (classify, embed, predict), not the *runtime*. Rejected.

**Per-feature targets (`BCIIntentClassifier`, `BCIEmbedder`,
`BCILLM`).** Finer-grained separation, but the targets would each
contain one type and a thin Core ML or MLX wrapper, with no shared
infrastructure to justify the boundary. The runtime-based grouping
(`BCIClassifier` for all Core ML models, `BCILLM` for MLX) is the
right grain. Rejected for now; revisit if a second Core ML model
creates real duplication within `BCIClassifier`.

## What this prevents

A future contributor adding a Core ML model and an MLX model to the
same target, which would duplicate the MLX runtime symbols in the
linked binary, create version-update coupling between the two
runtimes, and complicate the build (mlx-swift requires full Xcode
to compile its Metal kernels — only `BCILLM` should pay that cost).

It also prevents a contributor from importing `CoreML` or `MLX` in
`BCICore` or `BCIEEG` for "convenience" — a small convenience that
silently couples the shared layer to a specific runtime.

## When this rule does not apply

The test targets. A test that needs to verify cross-runtime behavior
(e.g., that a Core ML classifier's output is consumable by an MLX
predictor through a shared protocol) may `@testable import` both
targets. The rule is about production linkage, not test linkage.

A future contributor may also add a new runtime — e.g., a custom
Metal kernel for feature extraction — under a new target, provided
the new target is the *only* one importing the new runtime. The rule
is "one runtime per target," not "only two runtimes exist."

## Related implementation

- `Package.swift` — the dependency graph that enforces this rule
- `Sources/BCIClassifier/CoreMLIntentClassifier.swift` — Core ML
  adapter, ANE-preferred via `MLComputeUnits`
- `Sources/BCILLM/MLXNextWordPredictor.swift` — MLX adapter, the
  only target that imports `mlx-swift`
- `Sources/BCICore/Protocols/IntentClassifying.swift` and
  `Sources/BCICore/Protocols/NextWordPredicting.swift` — the
  public protocol surfaces that decouple consumers from the
  specific runtime
