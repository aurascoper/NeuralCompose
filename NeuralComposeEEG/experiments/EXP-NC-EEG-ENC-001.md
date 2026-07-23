# EXP-NC-EEG-ENC-001: Four-Channel Encoder Benchmark

## Question

Given the same four-channel Muse EEG windows, labels, preprocessing, and
session-grouped splits, do frozen EEGPT or BENDR representations improve
held-out observable-state discrimination, calibration, and cross-session
stability over deterministic features or EEGNet?

This experiment does not evaluate dialogue policy, thought decoding, ARC,
Qwen, or live BCI control.

## Fixed input and evaluation contract

- channels: `TP9`, `AF7`, `AF8`, `TP10`;
- sample rate: 256 Hz;
- primary window: four seconds / 1,024 samples; stride: one second;
- labels: only protocol-observable calibration and artifact blocks;
- grouping unit: complete recording session;
- normalization: per-session using calibration-only samples that precede task
  blocks;
- held-out sessions are never used to fit a feature scaler, model, class
  weights, or model-selection rule;
- overlapping windows never cross train/test boundaries because entire
  sessions are held out.

## Conditions

`M0` deterministic features plus regularized logistic regression; `M1` EEGNet
from scratch; `M2` random-initialized EEGPT control; `M3` frozen EEGPT; `M4`
frozen BENDR convolutional feature encoder. Only an explicit four-channel
adapter and a missing-channel mask are accepted for pretrained conditions. A
zero-filled montage without a mask is a negative control (`A4`), not evidence
of transfer. M4 does not claim to evaluate BENDR's separate contextualizer.

## Pilot interpretation

This is a pipeline pilot. Every result is emitted with
`status: insufficient_evidence`, `shadow_only: true`,
`live_control: false`, and `promotion_status: not_eligible`.

The confirmation gate is intentionally deferred until enough independent
recording sessions, days, participants, headset fits, and labels exist to
support grouped comparison. No result from this experiment changes the app.

Each evaluation artifact also records elapsed training/evaluation time, peak
process memory, per-window inference latency, estimated checkpoint size, and
an explicit deployment state. The shared
[`configs/experiment-v0.json`](../configs/experiment-v0.json) pins the M0/M1,
M2/M3, M4, and fixed-control optimization budgets; workers attest to its
content hash and the evaluator refuses a report whose recorded settings differ.

During this offline pilot, Core ML conversion and CPU/GPU/Neural Engine
assignment are deliberately `not_attempted` / `not_measured`. Energy impact
remains unavailable unless a worker can report it. These are recorded as
missing measurements, never inferred from PyTorch's training accelerator.
