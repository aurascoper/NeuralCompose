# EXP-NC-EEG-JEPA-001: Four-Channel Predictive Representation Learning

**Status:** scope complete, not executed
**Classification:** Pass 1.5 encoder-objective comparison
**Current gate:** D0, foundational study only
**Earliest pipeline-evidence run:** D2, only under a separate preregistration
**Earliest scientific comparison:** D3, plus an approved pretraining-data gate
**Promotion status:** not_eligible
**Runtime dependency:** prohibited

## Question

> Does masked latent prediction produce more transferable, non-collapsed
> four-channel EEG representations than matched reconstruction and supervised
> baselines under complete-session held-out evaluation?

## Fixed Boundary

This experiment is separate from
[`EXP-NC-EEG-ENC-001`](EXP-NC-EEG-ENC-001.md). It does not rename, replace, or
modify M0-M4, `experiment-v0.json`, the acquisition protocol, four-channel
montage, sample rate, window geometry, labels, preprocessing, optimization
budgets, or pilot interpretation.

It is an offline encoder study. It does not authorize:

- a live JEPA process or checkpoint in NeuralCompose;
- raw EEG input to an LLM;
- thought, semantic, intention, or emotion inference;
- new protocol labels or dialogue-derived labels;
- Core ML or ANE deployment;
- action-conditioned world modeling, latent MPC, or generation control; or
- promotion from a pilot result.

The estimand is the held-out difference in protocol-observable state
discrimination, calibration, artifact behavior, and robustness attributable to
the preregistered training objective under matched conditions.

## Entry Gates

At D0, only this contract, the
[`jepa-collapse-diagnostics-v0`](../../docs/scoping/jepa-collapse-diagnostics-v0.json)
schema, and deterministic diagnostic fixtures may be reviewed.

D1 remains one integrity-valid physical capture with no encoder training. D2
remains the multi-day M0/M1 pipeline cohort. A tiny JEPA run at D2 is permitted
only by a separate preregistration and can establish pipeline execution only.
It remains `insufficient_evidence` and cannot support confirmation, encoder
selection, construct language, or promotion.

D3 is the first gate for a defensible session-grouped JEPA comparison. It
requires ordinary grouped encoder evidence and a separate amendment approving
adequate self-supervised pretraining data. Post-encoder latent-transition,
world-model, or MPC work requires another action-conditioned experiment and is
not a continuation of this contract.

Before execution, the amendment must pin the corpus and licenses, participant
and session overlap audit, minimum independent data support, context/target
geometry, masking distributions, architecture, parameter-count tolerance,
optimization budget, seeds, probe protocol, grouped splits, collapse
thresholds, and compute ceiling.

## Conditions

| ID | Condition | Role |
| --- | --- | --- |
| J0 | unchanged EEGNet reference | supervised reference |
| J1 | matched encoder plus masked raw-signal reconstruction | reconstruction baseline |
| J2 | matched encoder plus latent prediction, no SIGReg or VICReg term | no-regularization ablation |
| J3 | matched encoder plus latent prediction and SIGReg | LeJEPA-style condition |
| J4 | matched encoder plus latent prediction and VICReg-style regularization | alternate anti-collapse condition |
| J5 | latent prediction plus bounded reconstruction auxiliary | hybrid objective |
| J6 | frozen Laya-compatible transfer condition | optional external transfer comparator |

J1-J5 use the same encoder capacity, parameter-count tolerance, train
partitions, batch exposure, optimization steps, mask schedule, and downstream
probe budget wherever the objective itself does not require a difference.
Every mismatch is reported and prevents a causal claim about the objective.
For J3 and J4, the preregistration names the encoder or projector tensor that
receives anti-collapse pressure. Applying SIGReg or VICReg-style terms only to
the predictor output invalidates the condition.

J6 may run only when an official checkpoint and reproducible implementation
are available, their license permits local evaluation, model and code revisions
are pinned, and the input adapter is explicit. J6 is not included in the
matched-objective attribution claim.

## Data Contract

The downstream input remains four-channel Muse EEG at `TP9`, `AF7`, `AF8`,
and `TP10`, sampled at 256 Hz in four-second windows with one-second stride.
Labels remain the protocol-observable blocks already admitted by the canonical
source manifest.

Short local pilot captures are not assumed sufficient for self-supervised
pretraining. A later execution must use one of:

1. licensed external public EEG for pretraining, followed by an explicit
   four-channel adapter and complete-session local probing; or
2. a substantial local unlabeled cohort with the outer grouped folds created
   before pretraining and a separate encoder fit for every training partition.

For local pretraining, no held-out session may contribute raw windows,
normalization, target views, mask statistics, early stopping, architecture
selection, or collapse thresholds. Hiding its labels is insufficient.

## Controls

All applicable conditions retain:

- temporal-target permutation;
- context and target drawn from different sessions;
- channel-coordinate shuffle;
- channel-order shuffle;
- mask-location shuffle;
- J2 no-regularization ablation;
- constant-embedding detection;
- seeded random encoder; and
- J1 matched reconstruction.

The different-session target tests whether a model can succeed through global
session identity rather than temporal structure. Channel and coordinate
controls test whether claimed montage awareness depends on the correct Muse
topology.

## Representation Diagnostics

At every epoch of a trainable representation condition, use training and
inner-validation groups only to record:

- embedding variance by dimension;
- covariance off-diagonal magnitude;
- complete singular-value spectrum;
- entropy effective rank and pinned energy rank;
- condition number under a pinned singular-value floor;
- mean pairwise distance;
- nearest-neighbor session-identity rate;
- constant-output and feature-utilization checks;
- predictor loss;
- regularization loss; and
- frozen-protocol linear-probe performance.

The exact fields and interpretation constraints are in
[`jepa-collapse-diagnostics-v0.json`](../../docs/scoping/jepa-collapse-diagnostics-v0.json).
Representation geometry cannot independently support a model.

After the epoch, thresholds, and condition are frozen, compute the same
diagnostic bundle once on the outer held-out group. Outer-group diagnostics or
linear-probe scores never select an epoch, threshold, mask schedule,
architecture, or condition. A frozen external J6 condition has one
post-adaptation diagnostic report rather than a fictitious epoch series.

## Scientific Outcomes

Primary and required downstream outcomes are:

- balanced accuracy;
- macro F1;
- Brier score;
- expected calibration error;
- artifact sensitivity and specificity;
- cross-session degradation;
- data-efficiency curves; and
- robustness to channel dropout, EMG-like noise, and movement artifacts.

Report per-session, participant, recording-date, device, and headset-fit
results whenever the cohort supports those groups. Report training/evaluation
time, peak memory, checkpoint size, and latency as resource evidence, never as
a substitute for scientific performance.

## Grouped Evaluation and Leakage

Build complete-session outer folds before any data-derived fit. Use participant
or recording-date grouping when it is stricter and feasible. Within each fold:

1. fit normalization, encoder, adapter, class weights, probe, and selection
   rules from training data only;
2. choose early stopping and any hyperparameters from nested training groups;
3. freeze the complete condition before evaluating the outer held-out group;
4. bind every result to dataset, source-manifest, preprocessing, split,
   architecture, checkpoint, adapter, mask, seed, and diagnostic hashes; and
5. keep the same eligible windows and outer folds across J0-J6.

A globally pretrained local encoder that has seen the outer test sessions is
not a held-out condition, even when their labels were hidden.

## Decision Rules and Falsification

The preregistration amendment must name one primary downstream metric and its
minimum effect before physical execution. No D0 threshold is inferred from
synthetic fixtures.

The latent-prediction hypothesis is rejected or suspended when:

- J3-J5 fail to improve preregistered held-out outcomes over J0 and J1;
- gains disappear under complete-session or stricter grouping;
- correctly paired targets do not beat temporal permutation or
  different-session targets;
- representation variance, covariance, spectrum, effective rank, or
  pairwise-distance checks show collapse or threshold instability;
- nearest-neighbor session identity indicates that nuisance identity explains
  the representation;
- gains are isolated to one session, participant, model seed, or artifact;
- robustness and data-efficiency evidence do not survive the fixed controls;
  or
- a simpler matched baseline performs equivalently at lower complexity.

Survival of only a visually coherent projection, training-loss improvement, or
one collapse metric is insufficient.

## Three-Dimensional Visualization

A learned embedding is not assumed to be three-dimensional. Any workspace view
uses a fixed random projection, a training-fold-fitted PCA projection, or a
separately frozen projection artifact. Held-out sessions never fit the display
projection. The view is exploratory and is not an evaluation outcome.

## Artifacts

An executed study must emit:

- `nc-eeg-jepa-pretraining-provenance-v0`;
- `nc-eeg-jepa-collapse-report-v0`;
- `nc-eeg-jepa-fold-predictions-v0`; and
- `nc-eeg-jepa-evaluation-v0`.

Every artifact records `status: insufficient_evidence`,
`promotion_status: not_eligible`, `runtime_change: none`, and the immutable
provenance described above unless a later confirmation contract explicitly
authorizes another interpretation.

The rationale and evidence review are in the
[JEPA four-channel EEG decision
memo](../../docs/research/jepa-four-channel-eeg-decision-memo-v0.md).
