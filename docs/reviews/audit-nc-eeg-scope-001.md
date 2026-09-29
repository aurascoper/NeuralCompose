# AUDIT-NC-EEG-SCOPE-001

**Status:** complete
**Audited commit:** `a90a56f` on `docs/eeg-methods-scope`
**Scope:** documentation and contract audit only; no model execution, hardware,
private recordings, local manifests, or app runtime execution.

## Finding A — V1 Capture Helper Is Not Executable

**Severity:** critical

The documented `encoder-pilot-v1` command requires a protocol helper that
records the v1 schema, fixed preset, explicit block end timestamps, completion
state, duration, and immutable stimulus provenance. The audited helper cannot
accept the documented preset/audio arguments or emit those required fields,
while the manifest compiler correctly refuses logs that lack them.

The scope document remains correct: the first physical capture must be
collectable and integrity-valid before any encoder training. The defect is in
the implementation path, not in the research sequence.

## Finding B — One-Session Integrity Is Coupled To Experiment Eligibility

**Severity:** high

The source-manifest compiler requires two eligible sessions. That is appropriate
for an experiment dataset, but it prevents the first clean engineering capture
from being parsed, aligned, and validated on its own.

The required distinction is:

```text
capture integrity
  Can this individual recording be parsed, aligned, and trusted?

experiment eligibility
  Are enough independent sessions available to build and evaluate the benchmark?
```

Therefore a clean first session must be able to report:

```text
integrity_valid: true
experiment_eligible: false
reason: insufficient_session_count
```

It must never become eligible for encoder fitting or model evaluation solely
because its capture integrity is valid.

## Clean Results

- M0–M4 names and roles were consistent.
- `encoder-pilot-v1` consistently identified the protocol preset, while
  `nc-eeg-observable-protocol-v1` consistently identified the log schema.
- Pass 1 remained `insufficient_evidence`, shadow-only, and non-promotable.
- IMU, ARC/Qwen/Gemma, Core ML, inverse/forward modeling, and live control
  remained deferred.
- Repository-relative Markdown links resolved.

## Follow-up Boundary

A separate implementation task may only add:

1. executable `encoder-pilot-v1` helper support and immutable provenance;
2. a single-session integrity-validation path distinct from the two-session
   experiment manifest; and
3. focused regression tests.

It must not add dependencies, run models, alter experiment eligibility, access
private recordings, or introduce live control.
