# Eyes-Open / Eyes-Closed Step 0 Pre-registration v1

- Status: **frozen before post-selection session 1**
- Frozen: 2026-08-06
- Applies to: one-participant Muse S TP10 floor evaluation
- Selection data: excluded from fitting and evaluation
- Evaluation trigger: six eligible post-registration sessions, with no interim classifier runs

This document fixes the Step 0 analysis before more evaluation data is
collected. It is a pre-registration, not a report. Do not retro-edit it after
the first post-registration session. Any change requires a versioned successor
and a fresh evaluation set.

## Question and claim boundary

Primary question:

> Can a fixed, one-channel TP10 feature pipeline classify eyes-open versus
> eyes-closed windows out of session, while failing the corresponding time-index
> and shuffled-label null arms?

The only promotable claim is a **single-participant, single-channel Step 0
floor**. A pass does not establish:

- spatial EEG decoding;
- transfer to another participant or headband;
- sleep-stage classification;
- imagined-speech decoding;
- an SSL, EEGNet, EEGPT, or foundation-model result;
- sufficiency for any encoder that depends on central or occipital coverage.

## Disclosed channel selection

The channel choice is post-selection, and that selection is part of the record.

TP10 is the sole model input. It was selected after inspection of the two clean
protocol sessions below:

| Acquisition | Order | TP10 condition | TP10 time-index | TP9 condition | Selection role |
|---|---|---:|---:|---:|---|
| `muse_validation_20260806-110528` | ABBA | 3.0164x | 0.7291x | 1.4109x | exploratory selection |
| `muse_validation_20260806-111651` | BAAB | 3.2574x | 1.5570x | 1.1805x | exploratory confirmation |

The corresponding JSON SHA-256 values are:

- ABBA: `2a44a8865521ff29ca46504799b4009836cacb6ed231d5c2d49a166fe067092a`
- BAAB: `e586ef65906f5f28470f493f96ae1223b74d0af1ee24f7c1c759efdacba92eb8`

Earlier dry and contact-limited sessions were also inspected and are not
held-out data. No acquisition whose artifact timestamp is at or before
`20260806-111651` may enter model fitting, threshold selection, or evaluation.

Other channels are fixed as follows:

- **TP9:** negative diagnostic only. It is never a model feature and never an
  acceptance input. Its per-session condition, time-index, shuffle, and contact
  values are reported unchanged.
- **AF7:** excluded. It saturated in all three analyzable attended captures.
- **AF8:** excluded. A 1.75x live condition ratio survived temporal permutation
  at 3.08-5.26x, identifying amplitude rather than isolated spectral contrast.

Channel selection is now closed. Evaluation data cannot add a channel, remove
TP10, create an ensemble, or select the best channel post hoc.

## Collection contract

### Fixed size and order

The evaluation set contains **six eligible post-registration sessions**. The
eligible-session order is fixed before collection:

1. ABBA: open, closed, closed, open
2. BAAB: closed, open, open, closed
3. ABBA
4. BAAB
5. ABBA
6. BAAB

If an attempt is ineligible, retain and hash its artifacts, record the reason,
and repeat the same scheduled order. Stop after at most **eight total attempts**.
If six eligible sessions do not exist after attempt eight, stop with
`INCONCLUSIVE_INSUFFICIENT_ELIGIBLE_SESSIONS`; do not lower the criteria or run
the classifier on fewer sessions.

### Eligibility

Eligibility is mechanical and cannot use alpha ratios, classifier output, or
whether a session looks promising:

- `contact_preflight.status == "passed"`;
- `contact_preflight.override_used == false`;
- all four alpha blocks contain exactly 3,840 samples and have
  `short_block == false`;
- TP10 is `healthy` in every `alpha_block_contact` record under that session's
  stored inclusive RMS thresholds;
- `block_order` exactly matches the scheduled order;
- CSV, JSON, session metadata, and power-state artifacts exist and are hashed.

TP9, AF7, and AF8 contact do not determine eligibility because they are not
model inputs. Their failures remain reportable diagnostics. No epochs or blocks
may be removed after a session passes these rules.

### No interim model analysis

The acquisition validator may print its pre-registered physiological and null
diagnostics because those are needed to verify capture. Do not run the Step 0
feature pipeline, classifier, cross-validation, aggregate accuracy, or shuffled-
label analysis until the sixth eligible session is frozen. Collection does not
stop because single-session ratios rise or fall.

Before post-registration session 1, the analysis implementation and synthetic
tests must be committed. Record that commit in the evaluation manifest. After
collection starts, code changes require a versioned successor pre-registration
and fresh sessions; they cannot be evaluated on this six-session set.

## Fixed examples and features

Only TP10 is read. For each of the four alpha blocks:

1. discard the first 2.0 seconds, exactly as the acquisition validator does;
2. divide the retained 13.0 seconds into six non-overlapping 2.0-second windows;
3. discard the final 1.0-second remainder;
4. assign every window its block's eyes-open (`0`) or eyes-closed (`1`) label.

Each eligible session therefore contributes 24 windows: 12 open and 12 closed.
No overlap, artifact rejection, amplitude clipping, channel substitution, or
window deletion is allowed.

For each 512-sample window, compute Welch power with these fixed parameters:

- sampling rate: 256 Hz;
- Hann window;
- `nperseg = 256`;
- `noverlap = 128`;
- constant detrending;
- density scaling.

The feature vector, in fixed order, is:

1. `log10(delta_power + 1e-12)`, 1-4 Hz;
2. `log10(theta_power + 1e-12)`, 4-8 Hz;
3. `log10(alpha_power + 1e-12)`, 8-13 Hz;
4. `log10(beta_power + 1e-12)`, 13-30 Hz;
5. `log10((alpha_power + 1e-12) / (power_1_30_hz + 1e-12))`.

Band edges use `low <= frequency < high`, except 30 Hz is included in the
1-30 Hz denominator. No feature may be added, removed, transformed, or selected
using evaluation results.

## Fixed classifier and split

Use a scikit-learn `Pipeline` containing:

1. `StandardScaler()` fit only on each training fold;
2. `LogisticRegression(penalty="l2", C=1.0, solver="liblinear",
   class_weight=None, random_state=0, max_iter=1000)`.

There is no hyperparameter search, calibration, early stopping, neural model,
or alternate classifier.

Evaluation uses leave-one-session-out cross-validation over the six eligible
sessions. Every window from one session is held out together. Fit preprocessing
and the classifier on five sessions, predict the sixth, and concatenate the six
held-out prediction sets for the aggregate score. Window-level random splits
are forbidden.

## Null arms

All arms use the identical features, classifier, folds, and metric.

### N1: time-index labels

Replace the physiological label with block-position labels: blocks 1-2 are `0`
and blocks 3-4 are `1`. This is the classifier analogue of the acquisition
time-index control. Report aggregate and per-session balanced accuracy.

### N2: shuffled block labels

For seeds 0 through 99, use `numpy.random.default_rng(seed)` to independently
permute `[0, 0, 1, 1]` across the four whole blocks within each session. All six
windows from a block retain the same shuffled label. This preserves class
balance and within-block dependence. Re-run the full leave-one-session-out
pipeline for each seed and report the complete 100-score distribution plus its
95th percentile.

The acquisition validator's within-block temporal-permutation ratios remain
session diagnostics. They are reported but are not substituted for N2.

## Fixed metrics and decision

Primary metric: **balanced accuracy** over all held-out window predictions.
Also report each held-out session's balanced accuracy and a 95% session-cluster
bootstrap interval using 10,000 resamples of the six held-out sessions with
`numpy.random.default_rng(0)`.

The Step 0 floor is `PASS` only if every condition holds:

1. true-label aggregate balanced accuracy is at least **0.70**;
2. at least five of six held-out sessions have balanced accuracy at least
   **0.60**;
3. the session-cluster bootstrap lower bound is greater than **0.50**;
4. true-label accuracy exceeds time-index accuracy by at least **0.10**;
5. time-index accuracy is at most **0.60**;
6. true-label accuracy exceeds the shuffled-label 95th percentile by at least
   **0.10**.

Any failed condition yields `FAIL`. Fewer than six eligible sessions after the
attempt cap yields the inconclusive status defined above. There is no partial
pass and no promotion based on a favorable subset.

## Required output and provenance

The evaluation writes one machine-readable result containing:

- this pre-registration path and SHA-256;
- analysis commit and dirty-worktree status;
- six included session IDs and all attempted session IDs;
- source CSV and JSON SHA-256 values;
- each session's order, stored contact thresholds, preflight status, override
  flag, TP10 per-block contact classes, and power-state sidecar;
- exact package versions for Python, NumPy, SciPy, and scikit-learn;
- feature matrix shape and per-session window counts;
- aggregate and per-session true-label scores;
- time-index score;
- all 100 shuffled-label scores and their 95th percentile;
- bootstrap seed, resample count, and confidence interval;
- each acceptance condition and the final status.

Report TP9, AF7, and AF8 protocol diagnostics beside the model result, but do
not feed them into the model or decision.

## Failure and successor rule

The six-session set is spent after one preregistered evaluation, whether it
passes or fails. Do not tune features, channels, thresholds, classifier, or
session inclusion on it and then report a second score as confirmatory.

A revised analysis requires `eyes-open-closed-step0-preregistration_v2.md`, an
explicit account of what v1 taught, and a fresh post-v2 evaluation set. The v1
file and result remain unchanged.
