# EXP-NC-SVD-M0-001: Train-Only M0 Feature Reduction

**Status:** proposed, deferred until D2
**Classification:** B. Optional Pass 1 controlled experiment
**Earliest gate:** D2, source-manifest-eligible multi-day cohort
**Promotion status:** not_eligible
**Runtime dependency:** prohibited

## Question

> Under identical complete-session splits, does a preregistered train-only
> truncated-SVD feature path improve grouped calibration or generalization over
> unchanged M0?

## Fixed Boundary

This is a separate sensitivity study. It does not modify
EXP-NC-EEG-ENC-001, experiment-v0.json, feature extraction, labels, or model
budget. The unchanged M0 is training-fold standardization followed by the
existing L2 logistic regression with C = 1.

## Conditions

| ID | Condition |
| --- | --- |
| B0 | unchanged M0 |
| B1 | train-only non-whitened PCA/truncated-SVD features then unchanged L2 logistic head |
| B2 | train-only whitened PCA features then unchanged L2 logistic head |
| B3 | seeded random orthogonal projection at B1's per-fold dimension then unchanged head |
| B4 | preregistered no-SVD feature-count-matched deterministic selector, if available |

For each fold, rank is the smallest training-only rank reaching 0.95 cumulative
explained variance, bounded by 1 through min(p, n_train - 1). The 0.90 and
0.99 rules are reported as sensitivity analyses. Means, scales, components,
rank, and whitening floor are fit from the training partition only; held-out
sessions are transformed only by those stored fold artifacts.

A pseudoinverse/least-squares score may appear only as a numerical teaching
control. It is not mathematically equivalent to, and cannot replace, multiclass
logistic M0.

## Outcomes and Falsification

Use the existing grouped metrics: balanced accuracy where defined, macro F1,
Brier score, expected calibration error, artifact metrics, per-session
outcomes, runtime, and model size. Retire B1/B2 if they do not improve grouped
results over B0, lose to matched B3, destabilize retained rank, worsen artifact
behavior, or need test-informed selection.

## Artifact

Emit nc-eeg-svd-m0-evaluation-v0 with dataset/preprocessing/split hashes,
train-window digest, fitted-transform hashes, retained rank, singular-value
floor, held-out predictions, and result status. Any positive result is
supported_for_further_science only.

See the [SVD experiment roadmap](../../docs/scoping/svd-eeg-experiment-roadmap.md)
for shared controls and artifact rules.
