# JEPA for Four-Channel EEG: D0 Decision Memo

```yaml
status: scope_complete
track: Pass_1.5_non_runtime
data_gate: D0
decision: foundational_study_only
promotion_status: not_eligible
live_control: false
modify_EXP_NC_EEG_ENC_001: false
implement_live_JEPA: false
download_or_train_Laya_now: false
```

## Decision

Joint-embedding predictive learning is a credible future encoder-objective
comparison for NeuralCompose, but it is not part of the current first-capture
experiment. The proposed work is registered separately as
[`EXP-NC-EEG-JEPA-001`](../../NeuralComposeEEG/experiments/EXP-NC-EEG-JEPA-001.md),
a Pass 1.5 study that asks whether masked latent prediction yields
non-collapsed, transferable four-channel EEG representations under the same
complete-session evaluation discipline as the existing encoder benchmark.

At D0 this memo authorizes only research scoping, deterministic validation of
the diagnostic contract, and review of synthetic collapse fixtures. It does
not authorize model training, checkpoint download, new data collection,
preprocessing changes, application inference, Core ML conversion, or dialogue
control.

The next physical action remains one frozen `encoder-pilot-v1` Muse capture,
followed only by integrity, window, and deterministic replay validation.

## The Precise Architectural Claim

NeuralCompose already uses staged lossy abstraction:

```text
raw four-channel EEG
    -> deterministic signal features or an encoder
    -> a compact representation
    -> a downstream classifier or visualization
```

That is not itself a JEPA. A joint-embedding predictive architecture requires
a context representation, a target representation, a predictor trained in
latent space, and an explicit mechanism that prevents representational
collapse. A more accurate statement is:

> NeuralCompose already relies on staged lossy abstraction. A JEPA condition
> would test whether explicitly predictive latent learning can replace one
> part of that hand-designed compression without changing acquisition,
> observable labels, grouped evaluation, or rendering protocols.

The protocol boundary is valuable engineering evidence: a renderer can consume
a vector without knowing whether it came from a deterministic or learned
encoder. It is not scientific evidence that a learned representation is
meaningful.

## Encoder JEPA Versus World Model

This proposal is an encoder experiment, not an action-conditioned world model.

```text
Pass 1
    M0 deterministic features
    M1 EEGNet
    M2 random EEGPT control
    M3 frozen EEGPT
    M4 frozen BENDR encoder

Pass 1.5
    matched reconstruction and JEPA objectives
    frozen downstream probes
    complete-session evaluation

Pass 4
    state + action + next state + cost + legal interventions
    world-model or MPC experiment
```

The existing
[`ADR-006`](../architecture/decision-log/ADR-006-jepa-transition-capture.md)
governs a separate, opt-in action-transition corpus for the synthetic
world-model research path. It does not make that corpus eligible for this
encoder study, and this study does not authorize MPC, latent anchoring, or
automatic generation adaptation.

## What the Current Evidence Supports

Laya is a March 2026 preprint, revised in May 2026, that adapts LeJEPA to EEG.
Its reported architecture uses independent temporal patch embedding, a
coordinate-aware dynamic channel mixer, masked latent prediction,
stop-gradient targets, and SIGReg geometric regularization. Its pretraining
corpus contains 913,314 samples, 29,109 hours, 20,940 subjects, and 17 channel
topologies. Those scale and montage conditions are materially different from
short local recordings at `TP9`, `AF7`, `AF8`, and `TP10`.

The reported results are promising but mixed. Laya has the strongest mean
clinical balanced accuracy in its frozen linear-probe table and favorable
noise-ablation results, while other models remain stronger on several
individual BCI, artifact, epilepsy, OCD, schizophrenia, and sleep tasks.
These results support a hardware-specific comparison; they do not establish
that latent prediction is universally superior or that the result transfers
to a four-channel Muse.

Reconstruction and latent prediction are also not a settled binary choice.
STST-JEPA combines masked latent prediction with an auxiliary raw-signal
reconstruction term. A bounded hybrid condition is therefore scientifically
appropriate, provided it is matched to the other conditions and preregistered.

The papers are background evidence only. Their reported results do not define
an acceptance threshold or bind the experiment to a paper-specific
architecture.

```json
{
  "paper_provenance": [
    {
      "paper_title": "Laya: A LeJEPA Approach to EEG via Latent Prediction over Reconstruction",
      "version": "v2",
      "retrieved_date": "2026-07-23",
      "source_url": "https://arxiv.org/abs/2603.16281v2",
      "claim_scope": "background evidence only"
    },
    {
      "paper_title": "STST-JEPA: Shallow-Target Spatio-Temporal Joint Embedding Prediction Architecture For EEG Self-Supervised Learning",
      "version": "v1",
      "retrieved_date": "2026-07-23",
      "source_url": "https://arxiv.org/abs/2607.06629v1",
      "claim_scope": "background evidence only"
    }
  ]
}
```

## Collapse Is Measured Directly

Raw-signal reconstruction is not the primary collapse detector. A model may
reconstruct well while learning an inconvenient downstream representation,
and reconstruction error alone cannot establish feature diversity or
transferability.

For every trainable representation condition, the proposed experiment records
direct collapse diagnostics at every epoch on training and inner-validation
groups only:

- per-dimension embedding variance;
- covariance off-diagonal magnitude;
- the complete singular-value spectrum;
- entropy effective rank and a pinned energy-rank summary;
- condition number only under a recorded numerical floor;
- mean pairwise embedding distance;
- nearest-neighbor session-identity rate;
- constant-output and feature-utilization checks;
- predictor and regularization losses; and
- a frozen-protocol linear probe.

The machine-readable definitions live in
[`jepa-collapse-diagnostics-v0.json`](../scoping/jepa-collapse-diagnostics-v0.json).
No single geometry metric is an acceptance criterion. Representation
diagnostics support an interpretation only when session-held-out predictive,
calibration, artifact, and robustness evidence also survives.

The anti-collapse term must be attached to the named encoder or projector
representation. Applying it only to predictor outputs does not establish that
the encoder itself avoided collapse. After model selection is frozen, the same
diagnostic bundle is computed once on the outer held-out group; those values
cannot choose an epoch, threshold, or condition.

## Proposed Conditions

| ID | Condition | Purpose |
| --- | --- | --- |
| J0 | unchanged EEGNet reference | retain the ordinary supervised reference |
| J1 | matched encoder with masked raw-signal reconstruction | reconstruction baseline |
| J2 | matched encoder with latent prediction and no SIGReg/VICReg term | collapse-pressure ablation |
| J3 | matched encoder with latent prediction plus SIGReg | LeJEPA-style regularization condition |
| J4 | matched encoder with latent prediction plus VICReg-style variance/covariance regularization | alternative anti-collapse condition |
| J5 | latent prediction plus a bounded reconstruction auxiliary | hybrid objective |
| J6 | frozen Laya-compatible transfer | optional only with an official checkpoint and reproducible implementation |

J1 through J5 must match encoder capacity, parameter-count tolerance,
optimization steps, batch exposure, train partitions, mask schedule, and
downstream probe budget wherever the objective itself does not require a
difference. J6 is a transfer condition, not part of the matched-objective
causal comparison.

## Required Controls

The experiment retains:

- temporal-target permutation;
- context and target drawn from different sessions;
- channel-coordinate shuffle;
- channel-order shuffle;
- mask-location shuffle;
- the no-regularization condition J2;
- a constant-embedding detector;
- a seeded random encoder; and
- the matched reconstruction condition J1.

The different-session target is a particularly important negative control. If
it performs similarly to the correctly paired condition, the model may be
exploiting session or headset identity rather than temporal structure.

## Four-Channel and Data-Volume Gate

A model trained on only a few short Muse sessions can easily learn participant,
session, headset-fit, impedance, persistent muscle, device-noise, block-timing,
or stimulus signatures. Good training loss or a visually smooth embedding
does not distinguish those shortcuts from transferable EEG structure.

Two defensible pretraining paths may be preregistered later:

```text
licensed external public EEG
    -> self-supervised pretraining
    -> explicit four-channel Muse adapter
    -> complete-session local probing
```

or:

```text
substantial unlabeled local Muse corpus
    -> build outer complete-session folds first
    -> fit the encoder only on each fold's training sessions
    -> probe the untouched held-out sessions
```

Label hiding is not data independence. Pretraining once on every local session
and later withholding only the labels of a test session is leakage for this
question.

D0 permits contracts, synthetic fixtures, and validator tests only. D1 permits
optional read-only pipeline and collapse-metric smoke tests, with no JEPA
training. At D2, a separately preregistered tiny run may establish pipeline
execution only; it cannot support confirmation, selection, or promotion. The
first defensible session-grouped JEPA comparison remains D3 and additionally
requires a later amendment that pins:

- the pretraining corpus, license, checksums, and participant/session overlap
  audit;
- minimum independent participant, day, session, and headset-fit support;
- context/target duration and masking distributions;
- architecture and parameter-count matching tolerances;
- optimization and probe budgets;
- collapse thresholds and their training-only selection rules; and
- the complete grouped split manifest.

Reaching D2 or D3 does not waive any of these requirements. Post-encoder
latent transition, world-model, or MPC work remains a separate
action-conditioned experiment.

## Evaluation Outcomes

The scientific endpoint remains held-out observable-state performance, not
latent appearance:

- balanced accuracy;
- macro F1;
- Brier score;
- expected calibration error;
- artifact sensitivity and specificity;
- cross-session degradation;
- data-efficiency curves; and
- robustness to channel dropout, EMG-like noise, and movement artifacts.

All conditions use identical complete-session outer folds. Participant and
recording-date grouping supersede session grouping when the cohort supports
the stricter unit. Every scaler, encoder fit, adapter, probe, class weight,
threshold, and model-selection decision is learned from the training
partition only.

## Falsification and Interpretation

Reject or suspend the latent-prediction hypothesis when any of the following
holds:

- J3, J4, and J5 do not improve preregistered held-out outcomes over both J0
  and the matched reconstruction condition J1;
- apparent gains disappear under complete-session or stricter grouped splits;
- the correct temporal pairing does not beat different-session or permuted
  targets;
- results are driven by session identity, headset fit, one model, one day, or
  one participant;
- non-collapse diagnostics disagree materially across folds or survive only
  under a post-hoc threshold;
- downstream gains disappear under channel, mask, noise, or data-efficiency
  controls; or
- a simpler supervised or reconstruction baseline matches the result at lower
  compute and complexity.

A supported result means only that a predictive latent objective merits
further encoder science for this hardware and protocol. It does not validate
a cognitive state, a world model, or a production representation.

Every result remains:

```yaml
status: insufficient_evidence
promotion_status: not_eligible
runtime_change: none
```

until a separate confirmation and promotion review explicitly changes those
fields.

## Three-Dimensional Workspace Boundary

A JEPA embedding is not naturally three-dimensional. Any 3D display must use
one of:

- a fixed random projection;
- a PCA projection fit within the training partition; or
- a separately frozen, provenance-bound projection artifact.

A projection may never be fit using held-out sessions. Visual coherence,
clusters, trajectories, or attractive geometry are exploratory observations,
not encoder-selection metrics or evidence of physiological meaning.

## D0 Deliverables

D0 is complete when:

1. the proposed experiment and diagnostic contract are internally consistent;
2. links and JSON structure validate deterministically;
3. no current M0-M4 condition, acquisition contract, preprocessing path,
   runtime, dependency, or experiment budget changes; and
4. the roadmap keeps the first physical `encoder-pilot-v1` capture as the next
   acquisition action.

No Laya checkpoint or training corpus is downloaded under this decision.

## Primary References

- Panchavati et al., [Laya: A LeJEPA Approach to EEG via Latent Prediction
  over Reconstruction](https://arxiv.org/abs/2603.16281), arXiv:2603.16281v2,
  2026.
- Segal et al., [STST-JEPA: Shallow-Target Spatio-Temporal Joint Embedding
  Prediction Architecture for EEG Self-Supervised
  Learning](https://arxiv.org/abs/2607.06629), arXiv:2607.06629v1, 2026.
- Bardes et al., [VICReg: Variance-Invariance-Covariance Regularization for
  Self-Supervised Learning](https://arxiv.org/abs/2105.04906),
  arXiv:2105.04906, 2021.
