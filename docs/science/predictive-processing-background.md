# Predictive Processing as Background Motivation

```yaml
status: background_only
claim_scope: background evidence only
data_gate: D0
decision: insufficient_evidence
promotion_status: not_eligible
live_control: false
introduces_labels: false
artifact_fields_added: none
cognitive_state_inference_authorized: false
```

## Why this note exists

Predictive-processing accounts of autism — notably Peter Vermeulen's framing,
and the HIPPEA hypothesis (High, Inflexible Precision of Prediction Errors in
Autism, Van de Cruys et al.) — motivate a specific engineering question: *is it
worth measuring uncertainty and model disagreement at all, rather than only a
single argmax label?*

That motivation is legitimate and is why `predictive_entropy`,
`encoder_disagreement`, and `out_of_distribution_score` exist in the fused-state
contract at all. This note records the motivation so the design choice is not
mistaken for arbitrary metric-collecting.

**It records a reason to measure. It does not license an interpretation.**

## What this note does not do

It does not assert that a four-channel dry-electrode Muse montage can decode
cognitive, affective, or intentional state. It introduces no labels. It adds no
field to any artifact. Nothing downstream may cite it as evidence.

Specifically out of contract, and enforced by
`NeuralComposeEEG/tests/test_shadow_scope_contract.py`:

- No `state_focused`, `state_overwhelmed`, or comparable affective/cognitive
  label may enter `observable_state_probabilities`, which is restricted to
  protocol-observable states (`eyes_open`, `eyes_closed`, `listening`,
  `speaking`, `recovery`) plus the three artifact channels.
- No HIPPEA-derived or prediction-error-derived field may appear in an
  encoder-state, fused-state, or Qwen payload.
- No action that would *act on* an inferred state — for example injecting a
  contextual anchor — may enter the legal-action registry, which stays exactly
  `abstain`, `hold_state`, `request_operator_review`.

## The distinction that matters

```text
legitimate:  "the two encoders disagree and the fused distribution is diffuse"
             — a statement about the models

not licensed: "the user is experiencing high prediction error"
             — a statement about the person
```

`predictive_entropy` is the Shannon entropy of a fused probability vector over
protocol-observable states. `encoder_disagreement` is a distance between two
model outputs. Both are properties of the *estimator*, not of the participant.
Reading them as a cognitive readout is a claim requiring its own
preregistration, its own falsification criteria, a D3 gate, and hardware that
the current montage is not — the Muse channel set has nothing over the regions
such an inference would rest on.

## If this is ever to become a claim

It would need, at minimum: a separate experiment document with a
pre-registered threshold; an independent behavioural or self-report criterion
to validate against; session-grouped held-out evaluation; and negative controls
showing the metric does not track signal quality or artifact rate instead. None
of that exists. Until it does, this file is background reading.

## Sources

| Source | Claim scope |
|---|---|
| Vermeulen, *Autism as Context Blindness* | background evidence only |
| Van de Cruys et al., HIPPEA (Psychological Review, 2014) | background evidence only |

Neither source is evidence about this repository's data, hardware, or encoders.
