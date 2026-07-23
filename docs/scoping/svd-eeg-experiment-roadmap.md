# SVD EEG Experiment Roadmap

**Status:** proposed studies only
**Current gate:** D0
**Decision:** insufficient_evidence
**Promotion status:** not_eligible

This roadmap operationalizes the SVD decision in
[the SVD decision memo](../research/svd-four-channel-eeg-decision-memo_v1.md).
It does not amend
[EXP-NC-EEG-ENC-001](../../NeuralComposeEEG/experiments/EXP-NC-EEG-ENC-001.md),
the observable acquisition protocol, preprocessing, labels, optimization
budgets, or runtime behavior.

## Governing Boundaries

- Input remains exactly four Muse channels: TP9, AF7, AF8, and TP10.
- Every encoder-related evaluation splits complete recording sessions before
  any fitted SVD, PCA, or whitening operation.
- A diagnostic from one physical capture cannot establish a physical-data
  model claim and cannot change capture eligibility.
- SVD does not infer thought, semantics, intent, source location, or dialogue
  policy. It receives no dialogue data.
- A proposal that survives an experiment is at most
  supported_for_further_science; it is never a promotion to Rust, Swift,
  Core ML, or live control.

## Shared Artifact Requirements

Every executed proposal must publish a local-only, numeric artifact with these
fields:

| Field | Requirement |
| --- | --- |
| dataset_sha256 | canonical dataset hash or synthetic-fixture hash |
| preprocessing_sha256 | fixed preprocessing contract hash |
| split_manifest_sha256 | grouped split hash, or null for a D0 synthetic fixture |
| matrix_definition | exact rows, columns, centering, scaling, and dtype |
| svd_backend | library, version, and LAPACK/BLAS driver when exposed |
| singular_value_threshold | exact rule or null |
| retained_rank | exact value per fold or null |
| fit_scope | synthetic, per-window read-only, training partition only, or fold model only |
| random_seed | explicit integer or null |
| reconstruction_error | measured norm and dtype |
| status | insufficient_evidence, supported_for_further_science, or rejected |
| promotion_status | always not_eligible |
| runtime_dependency_authorized | always false |

The artifact stores hashes, numeric summaries, and provenance. Raw EEG,
private dialogue, model prompts, and local filesystem paths are not committed.

## Cross-Study Leakage Controls

| Risk | Required control |
| --- | --- |
| overlapping windows | split on complete recording session before fit; preserve split manifest |
| learned PCA/whitening | fit means, scales, components, floors, and rank only on train rows |
| rank chosen from result | use preregistered training-only rule; report sensitivity without selecting best test result |
| direct and SVD diagnostic comparison | synthetic faults have fixed truth labels; physical report does not revise capture eligibility |
| session imbalance | report per-session metric and aggregate without allowing one long session to define rank |
| random solver/control | pin seed, rank, oversamples, iterations, and random projection matrix hash |
| activation analysis | collect only after the fold model is frozen; analysis cannot change model prediction or selection |
| external representation | retain canonical dataset/split, fold-scoped adapter, checkpoint, mapping, and mask provenance |

Minimum negative controls are shuffled session labels, shuffled channel mapping
where a channel-aware representation is used, random orthogonal projection at
the matched dimension, retained-rank permutation or matched-rank control,
no-SVD baseline, synthetic rank-deficient fixtures, and synthetic full-rank
noisy fixtures. A control may be inapplicable only when the contract says why.

## EXP-NC-SVD-DIAG-001

### Question

> Do read-only singular-spectrum diagnostics identify capture or
> feature-matrix defects not already identified by simpler deterministic
> checks?

### Scope

- **Classification:** B. Optional Pass 1 controlled experiment.
- **Earliest synthetic execution:** D0.
- **Earliest physical report:** D1, after an integrity-valid capture.
- **Owner:** Engineering for capture fixtures/reporting; Science for analysis.
- **No encoder behavior change:** every output is report-only.

### Matrix, Baseline, and Controls

For each channel-centered spatial window, X has shape 4 by 1024. The candidate
report contains the four singular values, energy fractions, entropy effective
rank, and condition number only when a pinned numerical floor makes it finite.
A second report may describe the training-only standardized M0 feature matrix
Z_train once D2 data exists. The two reports must never be combined into one
notion of rank.

The direct baseline is channel variance, amplitude range, pairwise correlation,
difference RMS where defined, packet loss, signal-quality fields, and
missing-channel masks. D0 fixtures must contain known:

- flat/disconnected channel
- duplicated channel
- near-collinear channel
- common-mode contamination
- full-rank noisy window
- nonfinite/missing channel, rejected before SVD

Each fixture carries fixed defect truth. Float32 and float64 spectra are
compared; a conclusion that changes across the preregistered numerical
threshold sensitivity set is reported unstable.

### Outcomes, Falsification, and Artifact

Primary outcomes are deterministic reproducibility, defect sensitivity,
false-positive rate, and incremental value over the direct baseline. Reject the
SVD report if it detects no defect not already caught by direct checks, adds
false positives, or produces unstable conclusions across dtype/threshold
choices. A positive result supports retaining only a read-only report.

The artifact is nc-eeg-svd-diagnostic-report-v0 with fixture/capture hashes,
matrix definition, complete spectrum, direct-check comparison, threshold
sensitivity, and capture_eligibility_changed: false.

## EXP-NC-SVD-M0-001

### Question

> Under identical complete-session splits, does a preregistered train-only
> truncated-SVD feature path improve grouped calibration or generalization over
> the unchanged M0 baseline?

### Scope

- **Classification:** B. Optional Pass 1 controlled experiment.
- **Earliest execution:** D2, after a source-manifest-eligible multi-day
  cohort exists.
- **Owner:** Science with Engineering-owned canonical dataset.
- **Existing M0:** unchanged; this is a separate, named sensitivity study.

### Conditions

All conditions use the same canonical data, label order, grouped split
manifest, and existing M0 logistic-head budget. The baseline is current M0:
training-fold standardization plus L2 logistic regression with pinned C = 1.

| ID | Condition | Fit scope |
| --- | --- | --- |
| B0 | unchanged M0 | existing train-fold scaler and logistic fit |
| B1 | non-whitened PCA/truncated-SVD features plus unchanged L2 logistic head | training fold only |
| B2 | whitened PCA features plus unchanged L2 logistic head | training fold only |
| B3 | random orthogonal projection with B1's per-fold output dimension plus unchanged head | training fold scaling; map pinned by seed |
| B4 | no-SVD feature-count-matched deterministic selector, if preregistered | training fold only |

The primary rank is the smallest r reaching 0.95 cumulative explained variance
on the training standardized feature matrix, bounded by
1 <= r <= min(p, n_train - 1). The 0.90 and 0.99 rules are mandatory
sensitivity analyses, not a test-set rank search. Whitening uses a pinned
training-derived singular-value floor. No transformation is fit from test
windows, including calibration/task data in the held-out session.

An unregularized logistic condition is an optional numerical stress check, not
a candidate production baseline. A pseudoinverse/least-squares score is only a
mathematical control because it optimizes a different objective from multiclass
logistic regression.

### Outcomes, Falsification, and Artifact

Primary outcomes match the encoder program: balanced accuracy where defined,
macro F1, Brier score, expected calibration error, artifact metrics,
per-session results, training/inference time, and checkpoint size. The primary
comparison is B1 versus B0; B2/B3/B4 test whether any effect is just dimension
reduction or whitening.

Retire truncated-SVD features if they do not improve grouped held-out
calibration/generalization, lose to B3, have unstable fold ranks, worsen
artifact behavior, or rely on a test-informed choice. A positive result stays
supported_for_further_science; it cannot amend experiment-v0.json.

The artifact is nc-eeg-svd-m0-evaluation-v0 with per-fold train-window digest,
component/scaler hashes, explained variance, retained rank, singular-value
floor, predictions keyed by canonical raw-window hashes, and the canonical
split-manifest hash.

## EXP-NC-SVD-REP-001

### Question

> Do selected-model EEGPT/BENDR representations show more stable effective
> rank across held-out sessions than random-init, shuffled-mapping, and
> zero-fill controls?

### Scope and Contract

- **Classification:** D. Pass 3 computational or analysis tooling.
- **Earliest execution:** D3, after encoder evidence and a frozen
  representation contract; it does not select an encoder.
- **Owner:** Science and Computation.

Use the same canonical dataset, grouped split manifest, model checkpoint,
adapter contract, and experiment budget as the representation being described.
For each fold, collect named activations or embeddings only after the model
has finished training. Build per-session matrices with rows as a fixed number
of held-out windows and columns as a named layer dimension. Use seeded
subsampling when session counts differ.

Compare M2 random initialization, M3 EEGPT, M4 BENDR where eligible, plus the
required shuffled-map and zero-fill controls. Do not fit global PCA/whitening
across sessions. Do not use effective rank to tune adapter size, epochs, or
select a model.

### Outcomes, Falsification, and Artifact

Report spectral entropy effective rank, energy ranks at preregistered
thresholds, reconstruction curves, rank stability across session holdouts, and
association with existing held-out metrics as descriptive statistics. Reject a
pretraining interpretation if differences vanish under controls, are
threshold-sensitive, are session-specific, or lack the existing grouped
predictive/calibration evidence. A stable rank alone does not prove transfer.

The artifact is nc-eeg-svd-representation-report-v0, bound to canonical
dataset/split, checkpoint, adapter/mask, held-out group, layer identifier,
activation shape, subsampling seed, spectrum, thresholds, and controls.

## EXP-NC-SVD-INV-001

### Question

> In a synthetic forward model with known source and noise structure, do TSVD
> or Tikhonov regularizers improve reconstruction error and stability relative
> to an unregularized pseudoinverse?

### Scope and Required Preregistration

- **Classification:** C. Pass 2 inverse/forward-model method.
- **Earliest execution:** D3 and only after a specific forward-model
  hypothesis is approved.
- **Owner:** Science; Julia/Python reference implementation only.
- **Physical claim:** prohibited. This is not Muse source localization.

Before execution, name the discretized forward operator G, source/sensor
geometry, conductivity model, boundary assumptions, source target, noise
distribution/covariance, penalty L, metrics, and synthetic generator seeds.
Explain why the study does not make a human source-localization claim.

Compare unregularized pseudoinverse, simulation-selected TSVD,
identity-Tikhonov, and generalized SVD only when a real nonidentity L exists.
Evaluate unseen synthetic source/noise draws. Report source error, forward
residual, stability under noise/geometry perturbation, resolution/null-space
summaries, and regularization parameters.

Reject a regularizer if it does not reduce preregistered reconstruction or
stability metrics against the pseudoinverse, only works at a hand-picked noise
level, or is not robust under the stated sensitivity study. No result
authorizes physical Muse source localization, app input, or production code.

The artifact is nc-eeg-svd-inverse-synthetic-v0 with operator hash,
geometry/noise/penalty specification, precision, singular-value filters,
unseen synthetic seed sets, and physical_muse_claim: false.

## Method Sequence and Deferrals

    D0: verify fixture math and artifact formats only
      -> D1: optional read-only capture diagnostics
      -> D2: optional grouped M0 sensitivity experiment
      -> D3: representation diagnostics OR separately registered synthetic inverse study
      -> post_encoder: offline compression profiling only

The arrows are eligibility gates, not a commitment to run every method. A
failed or nonincremental study retires its SVD use instead of escalating it.

The following are explicitly deferred or rejected: spatial PCA-based source
estimates, temporal denoisers/SSA/DMD without a target, ICA/robust PCA/NMF/
tensor decomposition/autoencoders/CCA in Pass 1, randomized or incremental
SVD for current tiny matrices, online SVD-derived state, Swift/Rust/Core ML
integration, live control, and any upload of local EEG merely for SVD speed.
