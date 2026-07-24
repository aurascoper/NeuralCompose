# Research Program Gates

## EXP-NC-EEG-ENC-001

Current scope: a deterministic source contract, four-second canonical Muse
windows, M0/M1, runnable M2/M3 EEGPT workers and mapping controls, and a
checkpoint-pinned M4 BENDR convolutional encoder worker. The current local
recordings do not yet satisfy the immutable source manifest: they lack the
completed `encoder-pilot-v1` protocol log and a declared timestamp-clock
origin. They remain historical engineering captures, not scientific source
data, so no physical-data metric is reported.

`nc-eeg-observable-protocol-v1` is frozen for the next acquisition cycle:
fixed observable blocks, Unix-wall-clock cues, eight-second unlabeled gaps,
pinned stimulus hashes, live four-channel Muse S only, and categorical
transport rejection. The first compliant recording is an engineering capture;
the second may run M0/M1 as pipeline evidence only. Qwen, Gemma, ARC policy,
and all live model-driven behavior remain deferred until an encoder is chosen
through the staged offline evidence gates below.

The supporting [mathematics, physics, and methods
scope](../docs/scoping/eeg-mathematics-physics-methods-scope.md) separates the
linear-algebra, signal-processing, and evaluation foundations needed now from
later electroquasistatic, sensor-fusion, optimization, and shadow-policy work.
The [SVD decision memo](../docs/research/svd-four-channel-eeg-decision-memo_v1.md)
and [proposed SVD experiment roadmap](../docs/scoping/svd-eeg-experiment-roadmap.md)
classify singular-spectrum diagnostics and train-only feature reduction as
separate, non-runtime studies. At D0 they are foundational only: they do not
modify the fixed encoder conditions or authorize a physical-data claim.
Their contracts are [SVD diagnostics](experiments/EXP-NC-SVD-DIAG-001.md),
[M0 feature reduction](experiments/EXP-NC-SVD-M0-001.md),
[representation analysis](experiments/EXP-NC-SVD-REP-001.md), and the deferred
[synthetic inverse study](experiments/EXP-NC-SVD-INV-001.md).

The [JEPA decision
memo](../docs/research/jepa-four-channel-eeg-decision-memo-v0.md) and proposed
[`EXP-NC-EEG-JEPA-001`](experiments/EXP-NC-EEG-JEPA-001.md) define a separate
Pass 1.5 encoder-objective comparison. At D0 this is documentation and
deterministic diagnostic-contract work only. It does not alter M0-M4, authorize
Laya download or training, or create a live JEPA path. D2 may permit only a
separately preregistered tiny pipeline-evidence run; D3 is the first scientific
comparison and still requires an approved pretraining-data gate. The registered
[collapse diagnostics](../docs/scoping/jepa-collapse-diagnostics-v0.json)
measure representation geometry directly, but cannot support an encoder
without the existing grouped predictive, calibration, artifact, and robustness
evidence.

Gate to encoder confirmation: protocol-complete sessions on multiple days,
then M0, M1, M2, M3, and eventually M4 on the same session-grouped folds.
Any pretrained condition must beat its random initialization and mapping
controls while preserving calibration and artifact rejection. The comparison
ledger also proves all reports used the same dataset and exact grouped split;
it remains `insufficient_evidence` for every pilot run. It also rejects reports
without the shared fixed-compute configuration hash and retains runtime evidence
separately from predictive outcomes. Core ML conversion is deferred until a
compact candidate is selected by this offline evidence.

## EXP-NC-EEG-JEPA-001

Proposed Pass 1.5 work only. It compares matched reconstruction, latent
prediction, anti-collapse, and bounded hybrid objectives after the ordinary
encoder program reaches the applicable gate. D2 can establish pipeline
execution only under a separate preregistration. A scientific comparison waits
until D3 and a separately reviewed corpus is adequate for self-supervised
learning. Short pilot captures are not enough merely because their labels can
be hidden. Every local pretraining fit remains inside its outer
training-session partition.

This is not the existing action-conditioned `WorldModel/` JEPA spike. An
encoder representation does not become a transition model, MPC objective, or
dialogue controller. Every JEPA result remains `insufficient_evidence`,
`promotion_status: not_eligible`, and `runtime_change: none`.

### Synthetic JEPA rehearsal

[`EXP-NC-EEG-JEPA-SYN-000`](experiments/EXP-NC-EEG-JEPA-SYN-000.md) is the
separate executable path for deterministic S0-S6 objective, control, collapse,
grouping, and artifact checks. Its
[generator contract](../docs/scoping/jepa-synthetic-generators-v0.json)
prohibits fallback acquisition data and physical claims. The optional
[mode-stratified extension](experiments/EXP-NC-EEG-JEPA-SYN-MODE-000.md)
treats mirror, focus, reflective, and contemplative only as externally assigned
synthetic regimes. Neither rehearsal changes the D0 status of the physical
JEPA experiment or sets physical-study thresholds.

## EXP-NC-ARC-XFER-001

Deferred until the encoder experiment selects a *fixed* shadow-only state
representation. Its inputs are structured temporal state records, not raw EEG.
The eventual comparison is Q0 deterministic policy against matched Qwen
adapters Q1 through Q6, including equal-token unrelated-curriculum and
shuffled-ARC-target controls. It cannot begin by fine-tuning Qwen on these
unvalidated waveform windows.

## EXP-NC-CL-001

Deferred until both the encoder and shadow policy have a held-out baseline.
It will retain episodic evidence, cross-session semantic regularities, and an
eligible policy-training buffer separately. The base model, EEG encoder, and
deterministic safety controller remain frozen initially; only rollbackable
offline adapters may change after replay and session-held-out evaluation.
