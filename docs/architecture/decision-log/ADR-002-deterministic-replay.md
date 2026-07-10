# ADR-002: Deterministic replay as the validation backbone

**Status**: Accepted
**Date**: 2026-07-10

## Context

NeuralCompose is a real-time signal-processing system. The hardest
class of bugs to catch — and the most expensive to debug after they
ship — are nondeterministic regressions: a feature works on the
developer's machine, fails in production, and the failure cannot be
reproduced because the input signal was a live Muse session that no
longer exists.

Live hardware is also a poor environment for *iteration*: each Muse
session is different (electrode contact, muscle tension, ambient
noise), so a "regression" in a classifier or visualizer is hard to
distinguish from natural variation in the input.

## Decision

New visualization, classifier, and feature work is validated against
a recorded, byte-identical input before it's ever connected to live
hardware. The recorded input is committed to the repository as a
golden fixture (`Recordings/golden/`), and the regression suite
asserts that the pipeline output for that fixture is unchanged (or
changed in a deliberate, reviewed way).

The playback path is deterministic: `PlaybackEEGStream` with
`PlaybackPacing.normalized` and `PlaybackTiming.instant` produces the
same sample sequence for the same recording, every time, on every
machine. This guarantee is what CI correctness rests on, and any
change to the resampling algorithm or the CSV format is a breaking
change for the committed fixture, not just for callers.

## Alternatives Considered

**Live-hardware validation only.** Matches the actual deployment
context, but every test run is a different session, and a
nondeterministic regression can only be caught by running the
reproducer many times. Rejected as the primary validation path;
retained for end-to-end deployment checks.

**Mock-based unit tests only.** Fast and deterministic, but mocks
abstract away exactly the signal characteristics that the pipeline
needs to handle correctly (clipping, contact loss, motion artifacts).
A green mock-based test suite does not prove the pipeline works on
real EEG. Rejected as the primary validation path; retained for
isolated unit tests of individual components.

**Recorded fixtures stored outside the repository (object storage,
S3, etc.).** Avoids bloating the repo, but introduces network
dependency in CI and makes the fixtures unavailable to contributors
working offline. The recordings used here are small enough (a few
hundred MB) that the trade-off is worth it. Rejected for now; revisit
if recordings grow.

## What this prevents

A new feature that works on the developer's machine, fails in
production, and cannot be reproduced because the input signal no
longer exists. With a deterministic golden fixture, every regression
that affects pipeline output is caught by CI before it merges.

It also prevents the "looks fine in my testing" failure mode for
classifier and visualizer work, where the developer ran the feature
on a few live sessions and called it done. The CI run on the golden
fixture is the source of truth.

## When this rule does not apply

New *acquisition-layer* code (a new `EEGStreaming` conformer, a new
hardware profile) has no replay equivalent and must be validated
against live hardware. A recorded Mind Monitor packet capture, a
recorded BLE session log, or a manual hardware bring-up is the
appropriate validation. The golden fixture is for analysis and
presentation code, not for code that talks to a sensor.

The rule also does not apply to changes that are *intended* to alter
the pipeline output. A new classifier, a new feature extractor, or a
new visualization *should* change the output; the regression
workflow is to update the committed fixture deliberately
(`NEURALCOMPOSE_REGENERATE_REFERENCE=1`) with a reviewed diff,
not to suppress the assertion.

## Related implementation

- `Sources/BCIEEG/PlaybackEEGStream.swift` — the deterministic
  playback path, including the `resample` algorithm whose
  byte-identical-output guarantee this rule depends on
- `Tests/BCIEEGTests/GoldenRecordingRegressionTests.swift` — the
  regression suite that pins the pipeline output
- `Recordings/golden/` — the committed fixture (regenerate with
  `NEURALCOMPOSE_REGENERATE_REFERENCE=1`)
- `Scripts/run-golden-recording.sh` — the runner that produces the
  fixture in a controlled environment
