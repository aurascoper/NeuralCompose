# EXP-NC-EEG-SHADOW-001: Offline Encoder-State Artifacts and Swift Replay

- **Status:** proposed, D0 contract and schema only; no encoder executed
- **Classification:** offline artifact production and replay, non-runtime
- **Current gate:** D0, foundational study only
- **Earliest physical compatibility check:** D2, artifact production only
- **Earliest physical encoder comparison:** D3
- **Earliest Qwen execution:** post-encoder, under a separate policy contract
- **Decision:** insufficient_evidence
- **Promotion status:** not_eligible
- **Runtime change:** none

## Question

> Can an encoder's per-window output be carried from an offline job into the
> application as an immutable, provenance-bound artifact, such that a synthetic
> record and a physical record are structurally distinguishable, the window
> geometry that produced each record is machine-checkable, and nothing in the
> path grants a model authority over user-facing behaviour?

This is an interface question, not a decoding question. It asks whether the
boundary holds — not whether EEG can be decoded, and not whether any encoder is
better than another.

## Architecture

```text
Muse recording (capture-integrity validated)
  → offline re-windowing            4 s / 1024 samples, 1 s stride
  → offline encoder job (W3 / W4)   EEGNet | frozen EEGPT + 4-ch adapter
  → nc-eeg-encoder-state-v0         one record per encoder per window
  → offline fusion (W5, F0–F2)      → nc-eeg-fused-state-v0
  → Swift replay bridge (W1)        strict decode → validate → telemetry
```

The excluded path, stated so it cannot be reintroduced by omission:

```text
Muse stream → live 2 s window → in-app encoder → generated state
  → speech / pacing / dialogue policy
```

## Fixed Boundary

- Encoders execute **offline only**. The application launches no encoder,
  no Python, and no model process (`ADR-011`).
- The application **reads validated artifacts and emits telemetry**. It grants
  no model authority over speech, pacing, dialogue policy, acquisition, or any
  user-facing behaviour.
- The live 2 s window is **not** a legal encoder input. Every record asserts
  `live_two_second_window_used: false` and `window_samples: 1024`.
- Synthetic and physical records are separated by a closed discriminated union.
  Neither branch can validate as the other.
- Failure disables only the affected shadow component. No encoder substitution,
  no local-to-cloud escalation.
- Embeddings may exist in encoder-state records for offline analysis. They are
  on the fusion contract's forbidden-field blocklist and never reach Qwen.

## Conditions

| ID | Condition | Role | Earliest physical gate |
|---|---|---|---|
| W1 | Swift replay of committed synthetic artifacts | interface evidence | not applicable |
| W2 | Offline encoder job protocol conformance | contract evidence | not applicable |
| W3 | EEGNet offline encoder job | baseline artifact producer | D2 |
| W4 | Frozen EEGPT + 4-channel adapter job | pretrained artifact producer | D2 compatibility; D3 comparison |
| W5 | F0–F2 fusion over encoder-state records | fusion artifact producer | D3 |

W3 and W4 are **artifact producers**, not a comparison. Any statement that one
encoder outperforms another requires D3 and a separate preregistration.

## Prerequisites

Neither is resolved by this experiment, and neither may be worked around.

1. **EEGPT checkpoint is unpinned.** `configs/eegpt-58ch-montage-v0.json`
   carries `"checkpoint_sha256": null`.

   ```yaml
   eegpt_checkpoint_status: unavailable_unpinned
   checkpoint_sha256: null
   W4_execution_authorized: false
   ```

   W4 entry additionally requires: a manually acquired checkpoint; its license
   recorded; the upstream code revision pinned; the checkpoint SHA-256; the
   channel-montage configuration hash; the adapter architecture hash; and
   confirmation of no overlap with held-out evaluation data. A placeholder
   64-character digest is worse than `null` and is prohibited.

2. **EEGNet is absent from the encoder-ID registry.** `contracts.py` admits
   only `eegpt` and `bendr`. Widening it is a named prerequisite for W3, made
   under its own change, not here.

## Outcomes and Falsification

The interface claim fails if any of the following holds:

- A synthetic record validates as physical, or a physical record validates
  without its capture-integrity hashes.
- A record produced from a 2 s window validates.
- Re-running a job with the same request, checkpoint, and seed yields a
  different `records_sha256`.
- A malformed record is partially accepted, coerced, or silently key-dropped by
  the Swift replay bridge.
- Any encoder-state field reaches the Qwen shadow-policy boundary beyond the
  bounded structured state already specified in `EXP-NC-EEG-FUSION-001`.
- Any artifact in this path changes application behaviour.

A passing interface says only that the boundary holds. It is not evidence that
any state is decodable, that any encoder is useful, or that a policy model is
warranted.

## D0 Artifacts

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
live_control: false
model_execution: false
weights_updated: false
```

Committed at D0: `schemas/nc-eeg-encoder-state-v0.schema.json`,
`PROTOCOL_OFFLINE_ENCODER.md`, this document, and
`tests/test_shadow_scope_contract.py`. No encoder weights, no job runner, and
no new recorded data.

The existing F0–F2 evidence bundle is **not** modified. Its byte identity is
part of its provenance, and a fusion encoder-output record is deliberately not
a valid `nc-eeg-encoder-state-v0` — the two artifact kinds must not be
interchangeable.

What a replay consumer may read:

```text
repository-tracked synthetic state fixture
  or
user-selected immutable local physical replay artifact
```

Physical encoder-state artifacts are local-only:

```yaml
stored_locally: true
git_eligible: false
raw_eeg_embedded: false
source_manifest_bound: true
```

No automatic directory search, and no import of historical recordings by
convention.

## Entry Gates

```text
D0:
  schema, protocol, and scope-contract tests only
  no encoder execution, no checkpoint acquisition

D2:
  EEGNet or pinned frozen EEGPT may produce artifacts from
  source-manifest-eligible recordings
  shape and artifact production only; not a comparison

D3:
  first session-grouped encoder or fusion comparison
  requires separate preregistration

post_encoder:
  structured-state shadow-policy experiment (W6, W7)
  under a separate policy contract
```

Passing D0 does not advance this experiment to D1, D2, or D3.
