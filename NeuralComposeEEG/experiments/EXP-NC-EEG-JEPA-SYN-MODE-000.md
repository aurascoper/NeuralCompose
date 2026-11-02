# EXP-NC-EEG-JEPA-SYN-MODE-000: Mode-Stratified Synthetic JEPA Rehearsal

**Status:** executable
**Parent:** [`EXP-NC-EEG-JEPA-SYN-000`](EXP-NC-EEG-JEPA-SYN-000.md)
**Decision:** `pipeline_evidence_only`
**Promotion status:** `not_eligible`
**Physical EEG claims:** prohibited
**Cognitive-mode inference:** prohibited

## Question

> Does the synthetic JEPA preserve predictable dynamics across four externally
> assigned generator regimes, use correct mode context rather than a shortcut,
> and generalize under leave-one-mode-out controls?

The labels `mirror`, `focus`, `reflective`, and `contemplative` mean only that
the deterministic generator was configured in that regime. They do not name
mental states and are not inferred from EEG, dialogue, or user behavior.

## Generator Regimes

| Mode | Controlled synthetic dynamics | Prohibited interpretation |
| --- | --- | --- |
| mirror | faster state tracking and short-range continuity | self-recognition |
| focus | lower transition rate and stronger persistence | attention detection |
| reflective | delayed transitions and longer dependence | reflection decoding |
| contemplative | slower low-frequency latent dynamics | meditation classification |

Noise, artifacts, mixing matrices, offsets, dropout patterns, frequencies, and
latent ranks are crossed independently of mode. No mode is one fixed waveform,
amplitude, session, block length, mask schedule, or nuisance family.

## Controls

| ID | Condition |
| --- | --- |
| C0 | mode-blind latent predictor |
| C1 | predictor receives the correct assigned mode |
| C2 | predictor receives a seeded shuffled mode |
| C3 | predictor receives one constant uninformative mode |
| C4 | mode-blind leave-one-mode-out evaluation |
| C5 | mode is available only to the downstream probe |

C0-C3 and C5 share complete-session folds. C4 trains on complete sessions from
three modes and evaluates complete sessions from the fourth, repeated for all
four modes. The model always contains the same mode-context input parameters;
blind and constant controls zero or replace values rather than changing model
capacity.

## Required Diagnostics

Collapse diagnostics are reported globally, per mode, on mode transitions when
present, and for every held-out-mode fold. Mode-neighbor identity is reported
alongside session-neighbor identity. Near-perfect mode clustering is a possible
shortcut, not independent evidence of a useful representation.

The extension can test whether correct explicit context improves synthetic
prediction, whether shuffled context removes that benefit, and whether a
mode-blind representation transfers to an unseen generator regime. It cannot
support a claim about human cognition or physical EEG.

## Physical Boundary

Adding real application modes to a physical acquisition protocol would require
a new protocol revision and a separate experiment with immutable mode events
and explicit speech, silence, audio, EMG, pacing, and block-timing controls.
This rehearsal does not relabel or amend the current observable-state encoder
experiment.
