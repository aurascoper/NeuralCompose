# Research

Versioned research artifacts that justify architectural decisions before
implementation begins. This directory is for *Design* work in the
Design/Verification/Runtime artifact taxonomy — it contains the
*evidence* and *rationale*, not the implementation.

## Convention

- Each artifact is a markdown file with a `_v1` (or higher) suffix in
  the filename when the content is intended to be versioned.
- A `README.md` accompanies each artifact if the filename alone isn't
  self-describing.
- Artifacts are reviewed (not auto-merged). A research artifact's
  audience is the next contributor who would otherwise re-derive the
  decision; if they would re-derive it, the artifact is too thin.
- Artifacts are *not* deprecated when superseded — they get a
  successor file with a higher version suffix. The successor's
  preamble cites the predecessor explicitly. This makes the decision
  history readable.

## What this directory is NOT

- It is not a place for *runtime* configuration, *benchmark JSON*,
  or *replay fixtures* — those are Verification or Runtime artifacts
  and live in `Tests/Fixtures/`, `Benchmarks/`, and the source tree
  respectively.
- It is not a place for high-level project overviews — those are
  `docs/Architecture.md` and the ADR series in
  `docs/architecture/decision-log/`.

## Current artifacts

| File | Stage | Status |
|---|---|---|
| [embedding-model-survey.md](embedding-model-survey.md) | 3.0 | Survey (this commit) |
| [methodology-review_v1.md](methodology-review_v1.md) | 3.4/3.5 | Review (superseded by v2) |
| [methodology-review_v2.md](methodology-review_v2.md) | 3.4/3.5 | Review (this commit) |
| [svd-four-channel-eeg-decision-memo_v1.md](svd-four-channel-eeg-decision-memo_v1.md) | EEG D0 | Foundational study only |
