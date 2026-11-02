# EXP-NC-EEG-JEPA-SYN-000: Synthetic JEPA Pipeline Rehearsal

**Status:** executable
**Classification:** deterministic synthetic pipeline rehearsal
**Source type:** `deterministic_synthetic_fixture`
**Physical EEG used:** false
**Decision:** `pipeline_evidence_only`
**Promotion status:** `not_eligible`
**Runtime change:** none

## Question

> Does the offline objective, masking, collapse-diagnostic, grouped-evaluation,
> and artifact pipeline distinguish preregistered synthetic structures and
> fail in expected ways under controlled negative cases?

This is not an execution of
[`EXP-NC-EEG-JEPA-001`](EXP-NC-EEG-JEPA-001.md). It cannot establish that
JEPA learns transferable Muse EEG representations and cannot set a threshold
for the later physical study.

## Source Boundary

The only admitted source is the dedicated deterministic generator specified by
[`jepa-synthetic-generators-v0`](../../docs/scoping/jepa-synthetic-generators-v0.json).
Its manifest uses `nc-eeg-jepa-synthetic-source-v0`, synthetic session IDs are
prefixed with `synthetic:`, `device_id` is `synthetic-generator`,
`participant_id` is null, and `physical_capture_eligible` is false.

NeuralCompose fallback-degraded or synthetic acquisition output is prohibited.
It remains evidence that live acquisition failed and must not enter this
experiment, the canonical physical source manifest, or a valid Muse session.

## Generators

| ID | Controlled structure | Expected use |
| --- | --- | --- |
| S0 | two mixed latent oscillators | low-rank and temporal-prediction checks |
| S1 | four independent noise channels | no-predictability negative control |
| S2 | shared common-mode transient | artifact-dominance check |
| S3 | session-specific nuisance signature | session-shortcut check |
| S4 | copied, flat, or missing channel | rank and provenance check |
| S5 | latent state-transition process | paired-target and probe check |
| S6 | weak-signal collapse trap | anti-collapse attachment check |

Every expected invariant is preregistered in the generator specification. A
failure identifies a pipeline defect or an inadequately specified synthetic
generator. It is not evidence against JEPA on EEG.

## Conditions

| ID | Condition |
| --- | --- |
| T0 | seeded random encoder |
| T1 | masked reconstruction |
| T2 | latent prediction without anti-collapse regularization |
| T3 | latent prediction plus SIGReg-style spectral pressure |
| T4 | latent prediction plus VICReg-style variance/covariance pressure |
| T5 | latent prediction plus bounded masked reconstruction |

T0-T5 instantiate the same encoder, projector, predictor, and decoder so total
parameter count is identical. T1-T5 use the same generated samples, complete
session folds, batch schedule, optimization steps, optimizer, seed,
context/target geometry, mask schedule, and probe budget. Objective-specific
inactive modules remain present but do not receive an invented loss.

For T3 and T4, anti-collapse pressure is applied to the named
`projector_embedding`. Predictor-output-only regularization invalidates the
condition. The EMA target is stop-gradient.

## Evaluation

Complete synthetic sessions are the split unit. Normalization, probes, and
every trained model are fit inside the training sessions of each outer fold.
Adjacent windows from one session cannot be split across train and test.

The rehearsal records:

- correct, temporally permuted, and different-session target losses;
- channel-order, coordinate, and mask-location controls;
- per-dimension variance and covariance;
- complete singular spectra, effective rank, energy rank, and condition number;
- pairwise distance, constant-output, and feature-utilization checks;
- nearest-neighbor session identity;
- predictor and regularization losses;
- a fixed-budget synthetic-state linear probe;
- non-finite rejection;
- checkpoint, source, configuration, code, and report hashes; and
- expected-invariant pass/fail results.

Synthetic thresholds are generator checks only. They cannot tune or justify
physical-study thresholds.

## Artifacts

The runner emits local ignored artifacts using:

```yaml
experiment_id: EXP-NC-EEG-JEPA-SYN-000
source_type: deterministic_synthetic_fixture
physical_eeg_used: false
scientific_transfer_claim_allowed: false
decision: pipeline_evidence_only
promotion_status: not_eligible
runtime_change: none
```

The synthetic source manifest is intentionally incompatible with the physical
Muse source schema.

Run the pinned rehearsal from the repository root:

```bash
PYTHONPATH=NeuralComposeEEG/src python3 -m neuralcompose_eeg.jepa_synthetic
```

## Prohibited Interpretations

This experiment cannot support physical artifact metrics, cross-session Muse
generalization, participant or headset robustness, physical data-efficiency
claims, encoder selection, Core ML conversion, app integration, or promotion.
It does not alter M0-M4, acquisition, preprocessing, or runtime behavior.
