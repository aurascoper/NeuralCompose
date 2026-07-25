# EEG Shadow Lab — MVP scope

Status: proposed (2026-07-24). Scope definition only; authorizes no implementation.
Governed by `decision-log/ADR-011-offline-eeg-encoder-artifact-boundary.md`.

This document names what the first useful EEGNet + EEGPT + fusion + Qwen product
actually is, so that it is not mistaken for something larger.

**It is an offline-analysis plus in-app shadow-replay research preview.**
It is **not** a live BCI assistant, and it is **not** a weight-fusion system.

```text
Muse recording
  → offline 4-second re-windowing
  → EEGNet and EEGPT run outside the app
  → immutable encoder-state artifacts
  → strict Swift import / replay
  → fixed F2 probability fusion
  → deterministic policy baseline
  → optional local Qwen shadow recommendation
  → telemetry only
```

No component speaks, changes pacing, modifies acquisition, or controls the user
experience. Nothing in this pipeline has live authority.

## Components

### EEGNet — the compact, task-specific baseline

Consumes exactly `[batch, 4, 1024]` over TP9, AF7, AF8, TP10 in the pinned
order; produces protocol-observable probabilities; records uncertainty,
checkpoint hash, configuration hash, and preprocessing hash. Runs as an offline
Python job and **never inside the packaged Swift application**.

Missing work:

```text
add eegnet to the encoder-ID registry
define a frozen EEGNet artifact format
implement the offline EEGNet job
pin checkpoint/configuration provenance
```

D0: synthetic fixtures only. D2: physical pipeline evidence.

### EEGPT — frozen backbone, explicit adapter

```text
frozen pretrained backbone
  + explicit four-channel Muse adapter
  + calibrated downstream probe
```

Stricter blockers: the checkpoint must be acquired manually and approved;
license and upstream revision recorded; checkpoint SHA-256 pinned; the
four-channel adapter architecture hashed; no held-out session may contribute to
adapter fitting. Random-init, shuffled-channel, and zero-fill remain
**science-only** conditions, never live-app conditions.

D2: compatibility and artifact generation only. A real comparison is D3.

### Fusion — F0–F2 only, no weight merging

| ID | Condition |
|---|---|
| F0 | EEGNet state alone |
| F1 | EEGPT state alone |
| F2 | fixed fusion of calibrated probabilities |

The fusion record exposes:

```json
{
  "eegnet_probabilities": {},
  "eegpt_probabilities": {},
  "fused_probabilities": {},
  "encoder_disagreement": 0.22,
  "predictive_entropy": 0.48,
  "signal_quality": 0.91,
  "shadow_only": true
}
```

F3 (logistic), F4 (MLP), F5 (uncertainty-gated mixture), and F6 (distillation)
remain later experiments.

**The app must never silently substitute one encoder for the other.** A missing
encoder yields an unavailable or incomplete state, surfaced as such.

### Qwen — inert shadow recommendation

`Qwen2.5-0.5B-Instruct-4bit` via MLX. The observed M4 result — 2.70 s load,
~30.5 tokens/second — shows the model is technically plausible on this
hardware. It remains **provisional**: that run came from a dirty checkout.

Qwen receives only the bounded structured state:

```json
{
  "signal_quality": 0.91,
  "artifact_probabilities": { "blink": 0.08, "jaw": 0.12, "movement": 0.16 },
  "observable_state_probabilities": {},
  "encoder_disagreement": 0.22,
  "predictive_entropy": 0.48,
  "legal_actions": ["abstain", "hold_state", "request_operator_review"]
}
```

Its output stays inert:

```json
{
  "selected_action": "hold_state",
  "reason_codes": ["high_predictive_entropy"],
  "predicted_outcome": { "uncertainty_delta": -0.04 }
}
```

Qwen must **not** receive raw EEG, unrestricted EEGPT embeddings, dialogue
transcripts, inferred emotion/intention/HIPPEA/cognitive state, arbitrary
action names, or permission to speak or alter the application.

The deterministic `P0` policy and the compact `P1` MLP/GRU baseline are
evaluated **before** Qwen `P2`. Without them there is no evidence the language
model contributes anything at all.

## Operator flow

1. NeuralCompose records an eligible local Muse session.
2. The operator runs the offline job:

   ```bash
   nc-eeg encode \
     --capture-manifest capture-manifest.json \
     --encoders eegnet,eegpt \
     --output session-encoder-states.jsonl
   ```

3. The job validates the capture, constructs canonical 4-second windows, runs
   EEGNet and EEGPT independently, writes to a temporary file, validates every
   record, computes hashes, and atomically publishes the completed artifact
   (`PROTOCOL_OFFLINE_ENCODER.md`).
4. In NeuralCompose the user chooses **Import Encoder-State Artifact**.
5. Swift verifies schema; source disposition; capture and integrity hashes;
   checkpoint identities; 4-second geometry; probability normalization; record
   ordering; absence of duplicate windows; and `completion_status: completed`.
6. The app replays the EEGNet and EEGPT states.
7. F2 computes or reads the fixed fused probabilities.
8. The deterministic policy and Qwen independently produce shadow
   recommendations.
9. The UI displays the disagreement:

   ```text
   Deterministic policy: abstain
   Qwen shadow:          hold_state
   No action executed
   ```

10. The result is logged locally as development/research telemetry.

Import is **user-selected**. There is no automatic directory scanning and no
import of historical recordings by convention.

## What ships in the research-preview DMG

Include: the strict encoder-state decoder; artifact importer; deterministic
replay; fused-state decoder or fixed F2 calculator; shadow diagnostics panel;
policy-output validator; and optional Qwen MLX integration behind an explicit
developer/research switch.

Do **not** bundle: Python; Julia; raw EEG; EEGNet or EEGPT training machinery;
public EEG corpora; Laya; unpinned checkpoints; dialogue corpora; LoRA
adapters. No model download at first launch.

EEGNet and EEGPT run from `NeuralComposeEEG/` outside the DMG; their outputs
enter the app as immutable artifacts. For Qwen, the safer first distribution is
a **separate, manually installed model pack with a pinned manifest** rather
than inflating the DMG or fetching weights at launch.

## Execution states

"Executing" is ambiguous as a boolean. It can mean the model ran once on a
fixture, or that it is embedded in the shipped app, or that it controls
something. Those are very different claims, so each subsystem carries a
graduated state instead:

```yaml
eegnet_execution:      none | synthetic_offline | physical_offline
eegpt_execution:       none | synthetic_adapter_smoke | physical_compatibility | physical_comparison
qwen_policy_execution: none | synthetic_shadow | physical_shadow
live_control:          false        # not a variable; never becomes true here
```

This lets all three subsystems execute meaningfully long before any live
authority exists — and makes it impossible to describe a fixture run as
physical evidence.

### Flip gates

A state advances only when its gate passes. Common to every flip:

```yaml
clean_checkout: true
python_ci: pass
job_status: completed
checkpoint_or_fixture_hash: recorded
nonfinite_outputs: 0
schema_failures: 0
swift_replay: pass
silent_fallback: false
```

Additionally, per state:

| State | Additional requirement |
|---|---|
| `eegnet_execution: synthetic_offline` | `eegnet` added to the encoder-ID registry; frozen artifact format defined |
| `eegnet_execution: physical_offline` | D2 eligible multi-day recordings; interpretation is `pipeline_evidence_only` |
| `eegpt_execution: synthetic_adapter_smoke` | shape, masking, missing-channel and replay gates pass on fixtures |
| `eegpt_execution: physical_compatibility` | D2; checkpoint manually acquired, licensed, revision and SHA-256 pinned, adapter architecture hashed |
| `eegpt_execution: physical_comparison` | D3; fold-local adapter/probe fitting, complete-session holdout, random-init / shuffled-channel / zero-fill controls |
| `qwen_policy_execution: synthetic_shadow` | P0 and P1 results recorded beside P2; MLX provenance complete; zero malformed outputs on the acceptance fixture; no cloud egress |
| `qwen_policy_execution: physical_shadow` | post_encoder; fresh grouped policy trajectories; separate preregistration |

No flip grants live authority. `live_control` stays `false` in every row.

## Two MVP levels

### Synthetic Shadow Lab MVP — buildable after branch stabilization

```yaml
eegnet_execution: synthetic_offline
eegpt_execution: synthetic_adapter_smoke
fusion_execution: synthetic_F0_F1_F2
qwen_policy_execution: synthetic_shadow

source_disposition: deterministic_synthetic_fixture
physical_eeg_used: false
scientific_claim_allowed: false
live_control: false
promotion_status: not_eligible
```

This is the first point at which all three subsystems are truthfully
"executing". It proves the complete app-facing integration end to end and says
nothing whatever about physical EEG.

### Physical Shadow Lab MVP — gated

```text
D1  one integrity-valid physical capture
D2  multiple eligible days; EEGNet pipeline evidence; EEGPT compatibility only
D3  grouped EEGNet/EEGPT/fusion comparison
post_encoder  deterministic/GRU/Qwen shadow-policy experiment
```

```yaml
eegnet_execution: physical_offline
eegpt_execution: physical_comparison
qwen_policy_execution: physical_shadow

live_control: false
promotion_status: not_eligible
```

A full physical MVP therefore sits **after D3 and encoder selection** — not
merely after the code compiles. Note that even here `live_control` remains
`false`: a physical shadow run is evidence, not authority.

## Release milestones

Calling this "v2" would imply a production transition that the evidence does
not support.

### NeuralCompose 0.2.0 — stability

```yaml
eegnet_execution: none
eegpt_execution: none
qwen_policy_execution: none
```


Prompt-resource fix (landed, PR #29); truthful runtime/provider UI; runtime and
CI stabilization; capture integrity; quarantine boundaries; W1 structured-state
artifact import and synthetic replay. **No EEG model or Qwen policy execution.**

The previously installed artifact was `0.1.0` build `1` and crashed in the
`Bundle.module → PromptProfile.load → LiveRuntimeFactory` path. This branch
still declares `0.1.0` / `1`. A clean 0.2.0 must first prove the product and
packaging boundaries are trustworthy — the version bump and the DMG tooling are
release prerequisites, not part of this planning package.

### NeuralCompose 0.3.0 Research Preview

Adds the offline EEGNet job; the offline frozen EEGPT job; artifact import;
F0–F2 shadow fusion; the deterministic policy baseline; and optional frozen
Qwen MLX shadow. **No live control.**

## Work still required

Before implementation:

```text
R2   Claude executable resolution
R3   Witness runtime/prompt separation
R8   truthful provider/privacy UI
R9   Python tests in CI
R16  SoakRuns ignore rules
R1   structured_state clean-checkout fix
     branch convergence into main
     W0 planning commit integration
```

Then the implementation PR train:

```text
W1  structured-state Swift replay
W2  offline encoder job protocol and CLI
W3  EEGNet offline job
W4  EEGPT frozen-backbone offline job
W5  F0–F2 fusion artifacts and replay
W6  deterministic and GRU/MLP policy baselines
W7  frozen Qwen shadow policy
    release research-preview DMG
```

## MVP acceptance gate

```yaml
clean_checkout_reproducible: true
python_ci: green
swift_build: green
packaged_app_smoke: green
dmg_signed_and_notarized: true

encoder_outputs:
  schema_valid: true
  provenance_complete: true
  deterministic_replay: true
  physical_and_synthetic_distinct: true

fusion:
  F0_F1_F2_only: true
  probabilities_valid: true
  missing_encoder_fails_closed: true

qwen:
  runtime: local_mlx
  raw_eeg_input: false
  output_schema_valid: true
  legal_actions_only: true
  deterministic_baseline_present: true
  live_authority: false

promotion_status: not_eligible
```
