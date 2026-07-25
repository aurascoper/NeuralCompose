# ADR-011: EEG encoders are offline artifact producers, not application runtime components

**Status**: Accepted
**Date**: 2026-07-24

## Context

The intended programme — EEGNet and EEGPT encoders, late fusion, and a local
Qwen shadow policy — was framed as *runtime integration*. Examining what the
repository can actually support showed that framing to be wrong for the
foreseeable stages.

Four facts constrain the design, each verified rather than assumed:

1. **The packaged app cannot host a Python worker.** `Scripts/package-app-bundle.sh`
   copies exactly the app binary, its dylibs, and `SpectralProbe` into
   `Contents/MacOS`. There is no interpreter in the bundle, no Swift code
   invokes Python, and embedding one is out of scope by policy.

2. **The window contracts disagree.** The app windows at 2 s
   (`Sources/BCICore/Preprocessing/EEGWindowing.swift`, constructed in
   `AppContainer.makeDefault()`). The encoder contract pins 4 s / 1024 samples
   (`NeuralComposeEEG/src/neuralcompose_eeg/contracts.py`,
   `configs/muse-four-channel-v0.json`), and every adapter hard-asserts
   `[B, 4, 1024]`. Stride agrees at 1 s; the window does not. A live 2 s window
   cannot feed an encoder without padding or duplication — both of which would
   silently manufacture evidence.

3. **The existing worker protocol is already file-based.** `run_eegpt_fold_worker.py`,
   `run_bendr_fold_worker.py`, and their evaluators exchange `.npz` + `.json`
   across machines. There is no IPC, no daemon, and no streaming path anywhere
   in `NeuralComposeEEG/`.

4. **No physical evidence exists.** `NeuralComposeEEG/ROADMAP.md` records that
   local recordings do not yet satisfy the source-manifest contract, so no
   physical-data metric is reported.

Taken together, the honest description of the next several stages is not
"runtime integration" but **an offline encoder artifact pipeline with a strict
Swift replay boundary**.

## Decision

**EEG encoders run offline and produce immutable, provenance-bound artifacts.
The application only ever reads validated artifacts. No encoder, fusion stage,
or policy model executes inside the packaged app.**

The boundary is artifact-based, matching the boundary already established for
the Julia science workspace:

```text
Muse recording (capture-integrity validated)
  → offline re-windowing to 4 s / 1024 samples
  → offline encoder job  (EEGNet | frozen EEGPT + 4-ch adapter)
  → nc-eeg-encoder-state-v0 records
  → offline fusion (F0–F2)
  → nc-eeg-fused-state-v0 records
  → Swift replay bridge: strict decode, validate, telemetry only
```

The path this forecloses:

```text
Muse stream → live 2 s window → in-app encoder → generated state
  → speech / pacing / dialogue policy
```

Five rules follow.

1. **Offline execution only.** Encoder jobs are CLI/operator-invoked, outside
   the app process. The app neither launches nor supervises them. Subprocess
   lifecycle is explicitly not part of this boundary.

2. **Artifacts are immutable and self-describing.** Every record carries its
   window geometry, source discrimination, encoder identity, and hashes.
   `nc-eeg-encoder-state-v0` uses a closed discriminated union so a synthetic
   fixture and a physical replay are distinguishable, and neither branch can
   validate as the other.

3. **The window boundary is machine-visible, not documentary.** Each record
   pins `window_samples: 1024`, carries `window_sha256` and
   `rewindowing_config_sha256`, and asserts `live_two_second_window_used: false`.
   Feeding the live 2 s window to a 1024-sample consumer is a validation
   failure, never a padded fallback.

4. **Swift reads; it does not compute.** The replay bridge decodes strictly
   (rejecting unknown keys), validates probabilities, and emits telemetry. It
   grants no model authority over speech, pacing, dialogue policy,
   acquisition, or any user-facing behaviour.

5. **Failure disables only the affected shadow component.** There is no
   substitution of one encoder for another, and no local-to-cloud escalation.

### Integration milestones — `W0–W7`

`W` names integration milestones only. `M/J/F/P/Q/S/T/C/FS/A` continue to name
experimental conditions. W6 and W7 deliberately **reuse** the existing policy
ladder in `NeuralComposeEEG/experiments/EXP-NC-EEG-FUSION-001.md` rather than
duplicating it; the separate `Q0–Q6` ARC ladder in `ROADMAP.md` remains
unreconciled and out of scope here.

| W | Milestone | Reuses | Synthetic gate | Physical gate |
|---|---|---|---|---|
| W0 | Planning and contracts (this ADR) | — | — | — |
| W1 | Structured-state replay bridge in Swift | — | D0 | — |
| W2 | Offline encoder job protocol | existing file handoff | D0 | — |
| W3 | EEGNet offline encoder job | `models.py` EEGNet | D0 fixture | **D2** pipeline evidence |
| W4 | Frozen EEGPT + 4-ch adapter job | `eegpt_adapter.py`, A0–A4 | D0 shape fixture | **D2 compatibility only; D3** for fitted adapter or probe comparison |
| W5 | F0–F2 fusion artifact generation | `fusion_contract.py` | D0 replay | **D3** grouped comparison |
| W6 | Policy baselines | existing `P0`, `P1` | fixtures | post_encoder |
| W7 | Frozen Qwen shadow policy | existing `P2` | synthetic states | post_encoder, separate preregistration |

At D2 a pinned frozen EEGPT checkpoint may be exercised for shape and artifact
production only. That cannot become an encoder comparison or an
adapter-selection result.

### Authority accounting

"No runtime change" is false once W1 adds Swift code. Implementation PRs
therefore report four separate fields rather than one:

```yaml
application_code_change: true
live_runtime_authority_change: none
model_execution_authority: none
behavioral_control_authority: none
```

Synthetic experiment artifacts continue to report `runtime_change: none`,
which is a statement about the *experiment*, not the codebase. The invariant
that matters: **no model gains live authority, and no generated state changes
speech, pacing, dialogue policy, acquisition, or user-facing behaviour.**

### Execution states, not booleans

Each subsystem carries a graduated state rather than a boolean, because
"executing" can mean ran-once-on-a-fixture, embedded-in-the-app, or
controls-something — three very different claims:

```yaml
eegnet_execution:      none | synthetic_offline | physical_offline
eegpt_execution:       none | synthetic_adapter_smoke | physical_compatibility | physical_comparison
qwen_policy_execution: none | synthetic_shadow | physical_shadow
live_control:          false        # not a variable
```

Per-state flip gates are in `../eeg-shadow-lab-mvp.md`. No flip grants live
authority.

### Fused-state schema versions

`nc-eeg-fused-state-v0` stays the **frozen D0 evidence schema** for the
committed `fusion-synthetic-v0` artifacts; those records are not migrated.

W5 targets `nc-eeg-fused-state-v1`, which adds per-encoder and fusion
completion status. v1 exists rather than an in-place amendment because v0
cannot represent a missing encoder: `fusion.status` is a `const` of
`"complete"`, and the probability fields are root-required, so an unavailable
fused state is unrepresentable without either weakening the closed contract or
invalidating committed evidence. In v1 a fusion marked
`unavailable_due_to_missing_encoder` is **forbidden** from carrying fused
probabilities, so losing an encoder cannot silently become a one-model
prediction.

### Compute budget — M4, 16 GB unified memory

Model residency is **sequential, never concurrent**, until measured otherwise
from a clean, pinned environment.

```text
W3 / W4   encoder resident            Qwen not resident
W5        no model resident           artifact transformation only
W7        encoder outputs materialized → unload encoder → load Qwen via MLX
```

The one available measurement is provisional and must not be used as an
acceptance threshold:

```yaml
Qwen2_5_0_5B_Instruct_4bit:
  load_seconds: 2.70
  first_token_seconds: 0.024
  throughput_tokens_per_second: 30.5
  evidence_quality: dirty_checkout_feasibility_only
```

It establishes only that the model *runs* on this hardware. It is not
reproducible from a clean checkout, is not packaged-app evidence, is not a
policy result, and is not evidence that Qwen improves any baseline.

### Failure matrix

| Condition | Behaviour | Never |
|---|---|---|
| Encoder checkpoint missing or hash mismatched | Job refuses to start; typed error | Run with an unpinned or substituted checkpoint |
| Artifact fails strict decode | Record rejected; component reports unavailable | Partial acceptance, coercion, or key-dropping |
| Probabilities non-finite or out of range | Record rejected | Renormalize silently |
| `live_two_second_window_used: true` | Record rejected | Pad or duplicate to 1024 samples |
| Physical branch missing integrity hashes | Record rejected | Admit as physical evidence |
| Encoder job absent or crashed | Shadow component disabled, reason surfaced | Substitute the other encoder |
| Local model unavailable | Feature disabled | Escalate to a cloud provider |
| Qwen output malformed | Rejected, abstain recorded | Retry with a loosened contract |

### Promotion map

```text
offline artifact  → replay validated  → shadow telemetry
                  → separate policy experiment
                  → (later, separately reviewed) any runtime consideration
```

Passing D0 does not advance an experiment to D1, D2, or D3. No stage in
W0–W7 promotes anything into live behaviour.

## Consequences

**Gained.** `runtime_change: none` stays literally true for the experiment
artifacts through W5. Determinism is free — artifacts are files with hashes and
replay byte-identically. No packaging, IPC, Core ML conversion, or cancellation
machinery is needed yet. The 2 s live path is untouched, so no existing
behaviour regresses. Synthetic and physical evidence cannot be confused,
structurally.

**Paid.** No live inference, so nothing here demonstrates latency or a
user-facing capability. Two encoder gaps must be closed before W3/W4 can run:
EEGPT's `checkpoint_sha256` is `null` in `configs/eegpt-58ch-montage-v0.json`
and must be pinned from a manually acquired, license-reviewed checkpoint; and
EEGNet exists only as an M1 from-scratch fold-trained baseline, absent from the
encoder-ID registry in `contracts.py`. Both are named prerequisites, not
changes made under this ADR. A placeholder 64-character digest would be worse
than `null`.

New Swift work is implied for W1. Because W1 launches nothing, it needs no
process machinery:

```text
New Swift work for W1:
- strict closed-object decoding;
- explicit unknown-key rejection;
- finite probability validation;
- probability-simplex validation;
- JSONL reading and line-level failure reporting;
- SHA-256 verification;
- replay ordering and duplicate-record checks;
- source-disposition enforcement;
- synthetic-versus-physical admission checks.

Explicitly deferred:
- subprocess execution;
- local worker lifecycle;
- timeout/cancellation utilities;
- Python invocation;
- model loading.
```

None of this exists today: nothing in Swift rejects unknown keys, there is no
probability validator, every JSONL path is write-only, and there is no
CryptoKit usage. A future in-app native helper — and any relocation of
`SubprocessProbe`/`AsyncTimeout` out of MLX-linked `BCILLM` — would require a
separate ADR. It is not part of this boundary.

### What W1 is allowed to read

```text
repository-tracked synthetic state fixture
  or
user-selected immutable local physical replay artifact
        ↓
Swift replay consumer
```

Future physical encoder-state artifacts do **not** belong in Git:

```yaml
stored_locally: true
git_eligible: false
raw_eeg_embedded: false
source_manifest_bound: true
```

The app may read a local validated artifact that the user selects. It must not
search arbitrary directories automatically, and it must not import historical
recordings by convention.

Governance tests added now are **local-only** until Python runs in CI. R9 needs
**two** non-vacuous discovery gates, because `NeuralComposeEEG/tests` alone does
not reach `Tests/eval` — where R1 surfaced:

```bash
PYTHONPATH=NeuralComposeEEG/src python3 -m unittest discover \
  -s NeuralComposeEEG/tests -p 'test_*.py' -v
PYTHONPATH=NeuralComposeEEG/src python3 -m unittest discover \
  -s Tests/eval -p 'test_*.py' -v
```

Before both become required checks, the pre-existing NumPy collection failure
and the R1 missing-module failure must be resolved, or isolated by an explicit
and temporary known-failure record. A hand-maintained file list is not an
acceptable substitute — it reproduces the omission problem it is meant to solve.

## Explicitly not decided here

- Whether encoders ever execute in-process, via Core ML export or otherwise.
- Any streaming, daemon, or IPC worker design.
- Whether EEGPT and Qwen may share memory concurrently.
- Which encoder is better — no comparison is authorized before D3.
- Whether BENDR, which is the only encoder with a pinned checkpoint and a
  working fold worker, becomes a fusion encoder. It remains an offline science
  asset; `fusion_contract.py` admits only `eegnet` and `eegpt`.
- Reconciliation of the `P0–P4` and `Q0–Q6` policy ladders.
- Any change to acquisition, the 2 s live window, or `EEGWindowingConfig`.
- Whether a policy model is needed at all. W6 exists to answer that before W7.
