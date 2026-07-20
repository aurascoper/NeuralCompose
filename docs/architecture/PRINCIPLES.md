# Architecture Principles

Engineering values that govern how NeuralCompose is built. These change
rarely — when one changes, every ADR written under it should be re-read
for consistency.

ADRs (`docs/architecture/decision-log/`) record *specific decisions* made
under these principles. Principles answer "how do we build software
here?"; ADRs answer "why did we make this choice?"

---

## 1. Protocols before implementations

Every subsystem is defined first by the protocol it conforms to, then
by any concrete type that satisfies the protocol. A new feature adds a
new protocol, not a new dependency on an existing concrete type.

This is what makes the codebase source-agnostic: the 3D workspace, the
plotter, the classifier, and the channel-health provider all read
`EEGStreaming`, never `BrainFlowService` or `MindMonitorOSCStream`
directly. Adding a fifth source (e.g., simulated, file-replay from a
remote collaborator) requires only a new conformer.

## 2. Hardware has a single owner

Each piece of live hardware (a Muse over BLE, a UDP socket, a BrainFlow
session) is opened exactly once per process. Multiple consumers
subscribe to the resulting stream through a multicast channel, not by
each opening their own session.

The cost of violating this is silent: two consumers each open a BLE
session, only one wins, the other gets nothing — and the failure mode
looks like "the second consumer is broken" rather than "we have a
shared-resource bug."

## 3. Deterministic replay before live validation

A new visualization, classifier, or feature is validated against a
recorded, byte-identical input before it's ever connected to live
hardware. Replay is the canonical regression source.

Live hardware is necessary for acquisition-layer code (which has no
replay equivalent) and for end-to-end deployment validation. It is
*not* the right environment for iterating on analysis or presentation
code, where nondeterminism makes regressions hard to distinguish from
real signal variation.

## 4. Frozen public APIs evolve additively

Once a public type is marked as a stable surface (see the "API
stability" doc comments on `EEGStreaming`, `IntentClassifying`,
`ChannelHealthProviding`, `NextWordPredicting`, `PlaybackEEGStream`,
`NeuralWorkspaceView`), it changes by addition only: new methods, new
fields, new conformers. Signature-breaking changes require a deliberate
review, an explicit version bump, and a regeneration of the regression
fixture if one depends on the changed type.

This is what makes the public surface small enough to be reviewable. A
type that can change at any time is a type nobody can rely on.

## 5. Privacy defaults to local execution

No outbound network calls at runtime. No telemetry. No analytics. No
"phone home." The default mode is fully offline; the user opts in to
anything that touches the network — the LAN OSC remote EEG source, and,
as a single deliberate and recorded exception, the opt-in Stage-5
hypnagogic loop's cloud LLM (which sends *transcript text only*, never
audio, and is off by default; see `decision_registry.md` entry 8) — and
every such opt-in is surfaced in the privacy indicator.

Local defaults also make the system testable in air-gapped
environments, which matters for clinical or research settings.

This principle is about network egress, not local persistence — see
`ADR-005-local-interaction-logging.md` for the opt-in, never-transmitted
interaction logger and why it doesn't conflict with "no telemetry."

## 6. Components communicate across protocol boundaries

The Intelligence layer does not know what produced the samples it
analyzes. The Interface layer does not know what produced the embeddings
it renders. The Runtime layer does not know what the Intelligence layer
will do with the samples it emits.

A component that needs to know about a non-adjacent layer is a sign
that either (a) the data flow should be redesigned, or (b) the missing
protocol should be added at the layer boundary where the knowledge
should live.

## 7. Every subsystem is independently testable

A new module comes with tests at three levels: a unit test against its
public protocol (no networking, no model loading, no SwiftUI), an
integration test against a real or fake boundary (a real loopback UDP
socket, a real `.mlpackage` if Core ML, a fixture CSV if playback),
and a regression test that pins the output of the existing pipeline
against a known-good recording.

A subsystem that can only be tested by running the full app is a
subsystem that can't be safely changed.
