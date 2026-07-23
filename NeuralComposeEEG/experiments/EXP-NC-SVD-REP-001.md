# EXP-NC-SVD-REP-001: Encoder Representation Rank

**Status:** proposed, deferred until D3
**Classification:** D. Pass 3 computational or analysis tooling
**Earliest gate:** D3, after encoder evidence and a frozen representation contract
**Promotion status:** not_eligible
**Runtime dependency:** prohibited

## Question

> Do selected-model EEGPT/BENDR representations show more stable effective
> rank across held-out sessions than random-init, shuffled-mapping, and
> zero-fill controls?

## Fixed Boundary

This is a descriptive representation study, not an encoder-selection criterion.
It does not alter a trained EEGNet, EEGPT, or BENDR condition. It does not fit a
global PCA or whitening map across sessions, and it never turns a rank plot
into evidence of transfer.

## Inputs and Controls

For a completed fold, collect named activations or adapter outputs only after
the model is frozen. Build a per-session matrix with a fixed seeded number of
held-out window rows and one named-layer dimension per column. Bind each report
to the canonical dataset, grouped split, model/checkpoint, adapter, and
missing-channel-mask provenance.

Compare M2 random initialization, M3 EEGPT, M4 BENDR where eligible, shuffled
mapping, and zero-fill controls. Existing M0/M1 predictive and calibration
reports remain independent evidence.

## Outcomes and Falsification

Report complete spectra, entropy effective rank, preregistered energy ranks,
reconstruction curves, and per-session stability. Reject an interpretation when
rank differences vanish under controls, are threshold-sensitive, are restricted
to one session, or lack the existing grouped predictive/calibration evidence.

## Artifact

Emit nc-eeg-svd-representation-report-v0 with the fold/group identifier,
activation shape, fixed subsampling seed, dtype, singular-spectrum summary,
thresholds, and all controls. The result can only motivate further science.

Shared leakage controls are in the
[SVD experiment roadmap](../../docs/scoping/svd-eeg-experiment-roadmap.md).
