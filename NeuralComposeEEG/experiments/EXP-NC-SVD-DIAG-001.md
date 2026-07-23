# EXP-NC-SVD-DIAG-001: Read-Only SVD Diagnostics

**Status:** proposed, not executed
**Classification:** B. Optional Pass 1 controlled experiment
**Earliest gate:** D0 for synthetic fixtures; D1 for a physical capture report
**Promotion status:** not_eligible
**Runtime dependency:** prohibited

## Question

> Do read-only singular-spectrum diagnostics identify capture or feature-matrix
> defects not already identified by simpler deterministic checks?

## Fixed Boundary

This proposal does not change capture eligibility, preprocessing, windows,
labels, M0-M4, or the application. It never receives dialogue data. A D1
report describes an integrity-valid capture only; it cannot establish a
physical-data model claim.

## Inputs

The spatial diagnostic uses a channel-centered four-channel window X with
shape 4 by 1024. It records the complete four-value singular spectrum, energy
fractions, entropy effective rank, and condition number only under a pinned
numerical floor. It labels raw-amplitude and calibration-z-scored matrices
separately.

The first baseline is existing direct evidence: channel variance, amplitude
range, pairwise correlation, difference RMS where defined, packet loss,
signal-quality fields, and missing-channel masks.

## Design

D0 synthetic fixtures have fixed truth for a flat/disconnected channel,
duplicated channel, near-collinear channel, common-mode contamination,
full-rank noise, and nonfinite/missing channel. Nonfinite/missing values are
rejected before SVD. The same fixture is evaluated in float32 and float64 with
a preregistered threshold sensitivity table.

A D1 report is read-only. It has no learned threshold, does not exclude a
capture, and does not feed an encoder or a feature extractor.

## Outcomes and Falsification

Primary outcomes are deterministic reproducibility, defect sensitivity,
false-positive rate, and incremental detections beyond direct checks. Retire the
report when direct checks detect the same defects with equal or lower
false-positive rate, or when conclusions change materially by dtype or
threshold.

## Artifact

Emit nc-eeg-svd-diagnostic-report-v0 with fixture/capture hash, matrix
definition, backend/dtype, spectrum, thresholds, direct-check comparison, and
capture_eligibility_changed: false.

The detailed shared controls are in the
[SVD experiment roadmap](../../docs/scoping/svd-eeg-experiment-roadmap.md).
