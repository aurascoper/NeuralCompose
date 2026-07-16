# ADR-005: Local interaction logging is not telemetry

**Status**: Accepted
**Date**: 2026-07-16

## Context

A pasted external proposal asked for an always-on `TelemetryLogger`
writing every (BCI cognitive state, prompt, response) interaction to a
JSONL file, as training data for a future local fine-tuning stage. The
name and framing ("telemetry") appeared to collide head-on with this
project's own stated principle: "No network at runtime. No cloud. No
telemetry." (`CLAUDE.md`, `README.md`, `PRINCIPLES.md` Principle 5).

Read literally out of context, "no telemetry" could be taken to forbid
any persistent record of what the user did with the app. That reading
turns out not to match what the principle actually protects. Principle
5's own text is "No outbound network calls at runtime. No telemetry.
No analytics. No 'phone home.'" — every clause is about data leaving
the machine. `ADR-004-privacy-first-acquisition.md` reached the same
conclusion when it added the OSC remote source: the default is local,
and network access is the thing that requires an explicit, visible
opt-in — not persistence itself. `Recordings/README.md` states the
project's actual data-locality commitment directly: captured EEG
"never leaves the machine," with no caveat against writing it to disk
in the first place. `CalibrationRecorder` already writes raw EEG,
labels, and session metadata to `~/Documents/NeuralCompose/Recordings/`
on every calibration run, and that has never been treated as a
"telemetry" violation.

So the actual question wasn't "is persistence allowed" — it already
demonstrably is, for EEG recordings — but whether a *new* kind of local
log (word commits + classified cognitive state, not raw EEG) should
exist at all, and if so, under what visibility contract.

## Decision

A local, opt-in, never-transmitted interaction logger is compatible
with Principle 5 and is built as such:

- `Sources/BCICore/Telemetry/TelemetryEvent.swift` — one record per
  word commit (`TextCompositionController.handleAction(.commitActive)`,
  the app's actual interaction unit — not a chat "prompt/response,"
  which this app doesn't have). Fields: the pre-commit composed-text
  context, the committed word, `SignalQuality`, the classified
  `SpectralState.badgeLabel` (never the raw continuous embedding — see
  "What this prevents"), and the `GenerationAdaptation` that was
  actually applied.
- `Sources/NeuralComposeApp/TelemetryLogger.swift` — an actor appending
  JSONL to `~/Documents/NeuralCompose/InteractionLogs/interactions-<date>.jsonl`,
  mirroring the dated-session convention `Recordings/night-<date>/`
  already uses. No `static let shared`; constructed by `AppContainer`
  like every other dependency in this codebase.
- Off by default. `AppViewModel.interactionLoggingEnabled` (default
  `false`) gates every write; `AppContainer`'s own default is a
  `NullInteractionLogger` so constructing a container in tests or
  previews never touches disk.
- Visible while active: `PrivacyIndicatorView` shows a persistent "●
  Logging" badge whenever the toggle is on (the same "obvious while
  recording" convention as a camera or mic indicator light), plus the
  file path, in the expanded panel — not just a settings-screen
  checkbox nobody sees again.

## Alternatives Considered

**No local logging at all.** Simplest, and the safest reading of "no
telemetry" if taken maximally literally. Rejected: it forecloses any
future locally-trained personalization work (the reason this was asked
for) without actually being required by what Principle 5 protects, and
the project already persists comparable data (`CalibrationRecorder`)
without controversy.

**Always-on logging, no toggle.** Matches the original pasted
proposal's shape. Rejected outright — every other privacy-relevant
capability in this app (`adaptiveComplexityEnabled`, the OSC remote
source) is opt-in and visibly surfaced; an always-on content log would
be the one exception, and a silent one at that.

**Log the raw 384-d spectral embedding, not just the classified
label.** Matches the original proposal, and would preserve more
information for a future training pipeline. Rejected for now:
`SpectralState.honestyCaveat` already commits this codebase to never
implying more precision from the spectral estimator than it actually
has ("heuristic gloss... not a validated cognitive-state read");
logging a continuous vector reads as more authoritative than that
caveat allows, and doing so would also require widening
`SpectralStateEstimating` to expose the pre-argmax embedding, which no
other consumer needs today. Revisit if a concrete downstream use
(Phase 5.0 or otherwise) actually needs it.

## What this prevents

A future contributor reading "no telemetry" literally and either (a)
ripping out this feature on sight, or (b) avoiding writing any
diagnostic/session data to disk at all, including things (like
`CalibrationRecorder`) the project already does on purpose. The
principle is about network egress; this ADR is the record of that
scope decision so it doesn't have to be re-derived from context every
time.

It also prevents this feature from silently drifting into something
closer to the original always-on proposal — the opt-in default and the
persistent "Logging" badge are load-bearing, not incidental, and a
change to either should update this ADR.

## When this rule does not apply

`Sources/GenerationEval/` and `Evaluation/` — the existing local
benchmarking harness. That's developer-run evaluation of candidate
models against a fixed prompt corpus, not user-interaction data, and
was never in tension with Principle 5 to begin with.

`Scripts/overnight-telemetry.py` — despite the name, this logs only
session/signal-quality metrics for the sleep-study protocol, never
prompt or response text, and is separate opt-in research tooling run
alongside the app, not inside it.

## Related implementation

- `Sources/BCICore/Telemetry/TelemetryEvent.swift` — the event type
- `Sources/BCICore/Protocols/InteractionLogging.swift` — the protocol
  + `NullInteractionLogger` default
- `Sources/NeuralComposeApp/TelemetryLogger.swift` — the JSONL actor
- `Sources/NeuralComposeApp/AppViewModel.swift` — `interactionLoggingEnabled`,
  `telemetryEvent(...)` (the pure commit-detection function), wiring in
  `apply(snapshot:)`
- `Sources/NeuralComposeApp/PrivacyIndicatorView.swift` — the toggle and
  the persistent "Logging" badge
- `docs/architecture/PRINCIPLES.md` Principle 5 — pointer to this ADR
- `docs/architecture/ROADMAP.md` Stage 4's "production telemetry" note —
  a different, narrower thing (instrumenting the routing/policy system
  once Stage 3.5 has evidence), not this feature
