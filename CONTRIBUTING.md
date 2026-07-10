# Contributing to NeuralCompose

## Before you start

Read these first. They are short and they set the context for every
other contribution:

1. [`README.md`](README.md) — what the project is, how to build it,
   the four-layer model
2. [`docs/architecture/PRINCIPLES.md`](docs/architecture/PRINCIPLES.md) —
   the engineering values that govern how new work is integrated
3. The relevant ADR(s) in
   [`docs/architecture/decision-log/`](docs/architecture/decision-log/) —
   the specific architectural decisions those principles produced

## Architectural decisions and ADRs

If your change is an *architectural decision* — a choice between
defensible alternatives where the converse could have been chosen
instead — write an ADR.

A new feature is not automatically an ADR. A refactor is not
automatically an ADR. The test is: *could the converse have been a
defensible choice?* If yes, the decision is architectural, and an
ADR is the right place to record it.

Examples of architectural decisions (ADR-worthy):

- Adding a new `EEGStreaming` conformer that uses a different
  transport (e.g., file-replay from a remote collaborator, a
  non-Muse EEG source)
- Changing the runtime split — e.g., moving a model from Core ML
  to MLX, or introducing a third runtime
- Changing the privacy posture — e.g., adding a feature that
  requires outbound network calls
- Restructuring a layer boundary — e.g., splitting the Intelligence
  layer into separate DSP and Inference sublayers

Examples of *non*-architectural decisions (no ADR needed):

- Adding a new feature within an existing layer (a new
  `IntentClassifying` implementation, a new `BCIClassifier` target)
- Refactoring an existing module without changing its public
  surface
- Performance optimization that doesn't change the protocol
  boundary
- Bug fixes (these belong in commit messages, not ADRs)

When you do write an ADR, use the seven-section format in
[`docs/architecture/decision-log/`](docs/architecture/decision-log/).
The "When this rule does not apply" section is the most-valuable
part: it's where the boundary of the decision is made explicit, and
where future contributors learn when the rule *isn't* the right
answer.

## Development workflow

1. **Branch off `main`.** The codebase is small enough that trunk-based
   development with short-lived branches is the right default.
2. **Write tests at three levels** for any new subsystem (see
   [Principle 7](docs/architecture/PRINCIPLES.md#7-every-subsystem-is-independently-testable)):
   unit tests against the public protocol, integration tests against
   a real or fake boundary, regression tests against the golden
   recording if your subsystem touches the pipeline.
3. **Validate against the golden recording** if your change touches
   any code between the channel-health provider and the 3D
   workspace. The regression suite will fail if the pipeline output
   drifts unintentionally.
4. **Reference the relevant ADR(s)** in your commit message. If your
   PR violates an ADR, the commit message should explain why and
   propose the corresponding ADR update.
5. **Keep the layer boundary clean.** The Interface layer should not
   import Core ML or MLX. The Runtime layer should not know about
   feature extraction. If you find yourself reaching across a
   boundary, the right move is usually to add a protocol at the
   boundary and inject the implementation, not to reach across.

## Code style

- Swift 6 strict concurrency. All new types are `Sendable`. Shared
  mutable state lives in actors, not in classes with locks. `@unchecked
  Sendable` is an escape hatch that requires a documented invariant.
- Public types get doc comments. The first paragraph is the summary;
  subsequent paragraphs cover edge cases, invariants, and "what this
  is not" disclaimers. Frozen types get an "API stability" section
  (see `EEGStreaming`, `IntentClassifying`, `ChannelHealthProviding`,
  `NextWordPredicting`, `PlaybackEEGStream`, `NeuralWorkspaceView`).
- New protocols come with a stub. The stub is the *only* conformer
  that ships in the same PR as the protocol; any concrete adapter
  ships in a follow-up PR. This is how the codebase validates the
  protocol before the implementation pressure distorts it.
- No new third-party SwiftPM dependencies without an ADR. MLX is
  `BCILLM` only. Core ML is `BCIClassifier` only. Everything else is
  `BCICore` (no third-party deps) or the specific target that owns
  the feature.
