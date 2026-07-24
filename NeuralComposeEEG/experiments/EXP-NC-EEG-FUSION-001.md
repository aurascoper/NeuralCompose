# EXP-NC-EEG-FUSION-001: Late Encoder-Evidence Fusion

- **Status:** proposed, D0 contract and synthetic interface fixture implemented
- **Classification:** post-encoder comparison, non-runtime
- **Current gate:** D0, foundational study only
- **Earliest physical compatibility check:** D1, read-only outputs only
- **Earliest physical fusion training:** D3
- **Earliest Qwen execution:** post-encoder, under a separate policy contract
- **Decision:** insufficient_evidence
- **Promotion status:** not_eligible
- **Runtime change:** none

## Question

> After EEGNet and EEGPT have each satisfied their own encoder evidence gates,
> does fold-local late fusion improve calibrated prediction of
> protocol-observable states over either frozen encoder alone?

This is not a model-weight fusion experiment. EEGNet, EEGPT, and Qwen have
different architectures, parameter spaces, inputs, and objectives. Their
tensors are not averaged, merged, or treated as interchangeable.

## Architecture

```text
four-channel EEG window
        |
        +-- EEGNet --> calibrated probabilities + compact embedding + uncertainty
        |
        +-- EEGPT --> calibrated probabilities + frozen embedding + uncertainty
                               |
                         fusion head
                               |
                    bounded fused EEG state
                               |
                  separately gated shadow policy
```

The encoder branches remain independent. The first learned fusion candidate is
a small, regularized logistic head fit inside each grouped training partition.
Qwen is not part of the encoder or fusion fit. A later frozen Qwen policy may
receive only the bounded structured state after the encoder program selects a
stable interface.

The machine-readable D0 contract is
[`fusion-synthetic-v0.json`](../configs/fusion-synthetic-v0.json). Its fused
state is closed by
[`nc-eeg-fused-state-v0.schema.json`](../schemas/nc-eeg-fused-state-v0.schema.json).

## Fixed Boundary

This experiment does not modify
[`EXP-NC-EEG-ENC-001`](EXP-NC-EEG-ENC-001.md), M0-M4,
[`experiment-v0.json`](../configs/experiment-v0.json), acquisition,
preprocessing, the four-channel montage, window geometry, protocol labels,
budgets, or promotion status.

It does not authorize:

- direct EEGNet/EEGPT/Qwen weight averaging or tensor merging;
- joint end-to-end training of EEGNet, EEGPT, and a fusion head;
- raw EEG, arbitrary encoder embeddings, or waveform tokens as Qwen input;
- Qwen execution, prompting, LoRA, prefix tuning, or online updates at D0;
- semantic, thought, emotion, intention, or agreement inference;
- physical-data threshold selection from synthetic fixtures;
- live dialogue, speech, application control, or runtime integration;
- Core ML conversion or deployment selection; or
- promotion from a compatibility or pilot result.

The current physical step remains one frozen `encoder-pilot-v1` Muse capture
for integrity, window, and deterministic replay validation only.

## Conditions

| ID | Condition | Role | Earliest physical gate |
| --- | --- | --- | --- |
| F0 | EEGNet alone | compact-encoder baseline | D3 |
| F1 | EEGPT alone | pretrained-representation baseline | D3 |
| F2 | fixed average of calibrated probabilities | parameter-free fusion baseline | D3 |
| F3 | train-only regularized logistic fusion head | first learned fusion condition | D3 |
| F4 | small MLP fusion head | nonlinear comparator | D3 |
| F5 | uncertainty-gated mixture of experts | reliability-aware comparator | D3 |
| F6 | EEGPT-to-EEGNet distillation | later deployment study | post-fusion evidence |

At D0, F0-F2 run only over synthetic output fixtures. F0 and F1 rehearse the
baseline interface and calibration metrics. Only F2 emits
`nc-eeg-fused-state-v0`; it has zero fitted parameters. F3-F6 are rejected by
the current executable contract.

## Frozen Encoders and Fold Locality

For the first physical fusion comparison:

```yaml
eegnet:
  frozen_within_fusion_stage: true

eegpt:
  pretrained_backbone_frozen: true

trainable:
  - four_channel_adapter
  - fusion_head
```

The EEGPT four-channel adapter and fusion head are fit only from the training
sessions of each outer fold. Scaling, calibration, missing-channel handling,
class weights, early stopping, and hyperparameter selection are also
training-partition operations. A held-out session contributes none of them.

For F3, the proposed input is:

```text
z = [
  calibrated EEGNet probabilities,
  EEGNet compact embedding,
  calibrated EEGPT probabilities,
  EEGPT embedding,
  EEGNet uncertainty,
  EEGPT uncertainty,
  signal quality,
  missing-channel fields
]
```

The head is a small regularized classifier. Its exact dimensions,
regularization, optimization budget, and parameter-count tolerance must be
pinned in a D3 amendment. No D0 fixture chooses those values.

## Required Controls

Every eventual fusion comparison includes:

- EEGNet alone;
- EEGPT alone;
- fixed calibrated-probability averaging;
- randomly initialized EEGPT with the same adapter;
- shuffled EEGPT embeddings;
- shuffled EEGNet embeddings;
- matched-dimension noise replacing one encoder;
- a matched-parameter-count fusion head;
- a session-identity probe;
- channel-map shuffle; and
- missing-channel control.

These controls test whether an apparent gain comes from an actual combination
of encoder evidence rather than parameter count, nuisance session identity,
one branch alone, or an implicit channel-map assumption.

Missing-model behavior is explicit. F2-F5 require both encoder outputs and fail
closed. There is no silent fallback that relabels one encoder as fusion.

## Outcomes and Falsification

The physical preregistration amendment must pin a primary metric and minimum
effect before D3. Required reporting includes:

- held-out balanced accuracy and macro F1;
- multiclass Brier score and expected calibration error;
- artifact sensitivity and specificity;
- encoder disagreement and predictive entropy;
- per-session and per-configuration results;
- robustness to channel dropout and the registered controls;
- parameter count, fit time, memory, and inference latency; and
- calibration and disagreement behavior when either encoder is confidently
  wrong.

Fusion is suspended or rejected when:

- F3 does not beat the stronger of F0, F1, and F2 under matched grouped folds;
- gains disappear under complete-session grouping;
- a shuffled, noise, or session-identity control explains the gain;
- calibration materially worsens despite a predictive improvement;
- one encoder or one session drives the result;
- adapter or feature fitting uses held-out sessions;
- missing-model behavior does not fail closed;
- the result depends on unregistered dimensions or a larger parameter budget;
  or
- a simpler condition performs equivalently.

No D0 synthetic metric supports the fusion hypothesis. D0 proves only that the
interfaces, calculations, serialization, and prohibitions are executable.

## Fused State Contract

The D0 state contains:

- protocol-observable state probabilities;
- artifact probabilities;
- signal quality and missing-channel identifiers;
- total-variation disagreement between encoders;
- normalized predictive entropy;
- a pinned synthetic OOD rehearsal score;
- encoder and adapter provenance; and
- deterministic synthetic checkpoint identity and SHA-256 for each encoder;
- fixed shadow-only, nonpromotion disposition.

It excludes waveforms, raw EEG, training labels, encoder embeddings, dialogue,
prompts, speech, and free-form text. Synthetic embeddings exist only in the
input fixture so the future interface shape can be validated; they are not
serialized into the state.

The D0 OOD score is a deterministic interface fixture:

```text
max(
  EEGNet uncertainty,
  EEGPT uncertainty,
  encoder disagreement,
  1 - signal quality
)
```

It is not a validated physical OOD detector or threshold.

## Qwen Boundary

Qwen remains a separate policy system. At D0 the repository may only render
and validate synthetic structured JSON. It does not call a model.

The staged policy sequence remains:

```text
P0  deterministic policy
P1  GRU or MLP policy
P2  frozen Qwen, prompt-only
P3  frozen Qwen plus learned input adapter
P4  Qwen LoRA on fresh, separately eligible policy trajectories
```

The current synthetic renderer admits only:

```text
signal quality
artifact probabilities
observable-state probabilities
encoder disagreement
predictive entropy
OOD score
```

It pins the task
`rank_registered_engineering_hypotheses_from_synthetic_fused_state`, three
legal shadow actions (`abstain`, `hold_state`, and
`request_operator_review`), and an exact ordered reason-code registry. Input
validation recursively rejects unknown or prohibited fields, non-finite JSON,
non-numeric probabilities, and non-normalized probability vectors. Output
validation rejects extra prose, illegal actions, state-ID mismatches, live
control, and weight-update claims.

Any future Qwen execution requires a separate post-encoder policy
preregistration with fresh session-level splits. It may rank registered
hypotheses, abstain, predict a structured next state, or select one legal
shadow action. It may not infer mental content, alter encoder thresholds,
speak, or control the app.

## Distillation Boundary

F6 is not a shortcut around encoder selection. If a validated EEGPT+EEGNet
teacher is too expensive for deployment, a later experiment may compare a
compact EEGNet student against fold-local teacher predictions. The teacher
that produces targets for a training fold must not have been fit on that
fold's held-out sessions.

Core ML evaluation begins only after this offline comparison selects a compact
candidate. It is not part of this contract.

## D0 Artifacts

Implemented now:

- the machine-readable F0-F6 and gate contract;
- a closed `nc-eeg-fused-state-v0` JSON Schema;
- six synthetic paired EEGNet/EEGPT output fixtures;
- deterministic F0, F1, and fixed F2 probability calculations;
- multiclass Brier and ECE rehearsal;
- total-variation disagreement and entropy calculations;
- fail-closed missing-model behavior;
- hash-bound replay serialization;
- bounded Qwen input rendering; and
- strict Qwen output validation.

The implementation is
[`fusion_contract.py`](../src/neuralcompose_eeg/fusion_contract.py), with
deterministic checks in
[`test_fusion_contract.py`](../tests/test_fusion_contract.py).
The committed
[`fusion-synthetic-v0`](../artifacts/fusion-synthetic-v0/) evidence bundle
contains the canonical fused-state replay, hash-bound manifest, and report;
the tests require byte-identical regeneration.

Every report remains:

```yaml
status: foundational_study_only
data_gate: D0
decision: insufficient_evidence
promotion_status: not_eligible
runtime_change: none
source_type: deterministic_synthetic_fixture
physical_eeg_used: false
scientific_claim_allowed: false
shadow_only: true
```

## Entry Gates

```text
D0:
  schemas, synthetic output fixtures, deterministic metrics, replay,
  and Qwen input/output validation only

D1:
  one physical session; read-only encoder-output compatibility only
  no fusion fitting and no threshold selection

D2:
  M0/M1 pipeline evidence under EXP-NC-EEG-ENC-001
  optional fusion smoke test only under a separate preregistration

D3:
  complete-session grouped EEGNet versus EEGPT versus fusion comparison
  frozen backbones and fold-local adapter/head fitting

post_encoder:
  separate structured-state shadow-policy experiment

post_policy_evidence:
  prefix/projector or LoRA comparison on fresh policy trajectories
```

Passing D0 does not advance the experiment to D1, D2, or D3.

## Background Evidence

The following sources motivate interfaces only. They are not acceptance
criteria and do not establish compatibility with NeuralCompose data.

| Source | Version or revision | Retrieved | Claim scope |
| --- | --- | --- | --- |
| [EEGNet](https://pubmed.ncbi.nlm.nih.gov/29932424/) | PMID 29932424 | 2026-07-24 | background evidence only |
| [EEGPT repository](https://github.com/BINE022/EEGPT) | upstream repository, revision must be pinned before execution | 2026-07-24 | background evidence only |
| [Qwen3-0.6B model card](https://huggingface.co/Qwen/Qwen3-0.6B) | upstream model card, revision must be pinned before execution | 2026-07-24 | background evidence only |
| [Channel adaptation benchmark](https://arxiv.org/abs/2604.23091) | arXiv:2604.23091 | 2026-07-24 | background evidence only |
