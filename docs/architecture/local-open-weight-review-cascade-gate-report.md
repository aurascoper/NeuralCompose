# Local Open-Weight Review Cascade Gate Report

**Date:** 2026-07-23

## Repository State

- branch at start: `feat/local-dialectic-review`
- draft PR base branch: `feat/dialectic-corpus-quarantine`
- base merge point with `main`: `611b07e0b6a1030cc01f27b3cf80dfd24286931f`
- starting commit: `6ae9b96`
- prerequisite history present: quarantine `b8c1336`, capture integrity
  `9726626`, encoder contract `a90a56f`, methods scope `0441c1c` and scope
  audit `3e1b55b`
- both the quarantine contract and structured EEG state bridge are present on
  the branch

The worktree contained unrelated application, telemetry, scientific-document,
packaging, and soak changes before this work began. They are not staged or
modified by this gate.

## Cascade Implementation

`Scripts/local_open_weight_review.py` adds R0 validation, configured R1/R2
attempts, optional manual-only R3 advisory adjudication, and R4 human-gate
documentation. R1 receives the frozen chunk; R2 receives that same chunk plus
R0 error codes only. R3 can be requested explicitly for an R0-valid finding,
but cannot override R0 or mutate a review result.

The narrow adapter surface supports loopback Ollama-compatible HTTP and a
deterministic mock. A stable local MLX service interface was not present, so no
MLX adapter or dependency was added. The cascade rejects a remote endpoint,
explicit cloud-routing model identity, missing local classification, unconfined
logging attestation, malformed disposition, source/report checksum mismatch,
and source mutation during review.

`configs/local-open-weight-review-v0.json` owns the model ladder, chunking,
generation settings, and retry bound. The implementation contains no model-name
selection logic.

## Privacy

No private corpus, local recording, or artifact beneath a local documents
directory was read for this work. All new tests use generated records and
synthetic EEG fixtures only. No model was downloaded or run.

Raw source records and model responses remain in memory for one request. The
only serializable outputs are metadata-only chunk receipts, summary, and run
manifest. Output directories must be outside the repository or Git-ignored.
The bounded private-text detector is documented as a guardrail rather than a
proof of privacy.

## EEG Noninterference

`Scripts/local_review_noninterference.py` verifies the required metadata-only
separation between review and EEG tracks. It rejects dialogue source or content
hashes in EEG artifacts or model inputs, review finding identifiers in experiment
configuration, EEG window hashes in review prompt metadata, shared training
buffers, dialogue embeddings, and dialogue-derived weight updates.

The existing structured-state bridge remains probability-only and was verified
with synthetic deterministic replay. It remains shadow-only and cannot become
physical-data evidence, speech, intervention selection, model update, or live
control through this change.

## Research Governance

`Scripts/research_decision_register.py` and
[`research-decision-register.schema.json`](../scoping/research-decision-register.schema.json)
validate governance metadata only. Every entry requires
`runtime_dependency_authorized: false`; it cannot authorize a dependency,
experiment, runtime feature, or promotion.

The existing four-pass order is unchanged. No mathematics, physics,
optimization, inverse modeling, PCA/ICA, policy/control, ARC, Core ML, encoder
architecture, preprocessing, label, budget, or promotion rule changed.

## Validation

```text
PYTHONPATH=NeuralComposeEEG/src python3 -m unittest -v \
  Tests/eval/test_local_open_weight_review.py \
  Tests/eval/test_dialectic_corpus_quarantine.py \
  Tests/eval/test_local_dialectic_review.py \
  NeuralComposeEEG.tests.test_pipeline \
  NeuralComposeEEG.tests.test_structured_state
# 66 passed

swift test --filter CalibrationRecorderTests
# 7 passed

python3 -m py_compile Scripts/local_open_weight_review.py \
  Scripts/local_review_noninterference.py \
  Scripts/research_decision_register.py \
  Scripts/quarantine_dialectic_corpus.py
# passed

python3 -m json.tool configs/local-open-weight-review-v0.json
python3 -m json.tool docs/scoping/research-decision-register.schema.json
# passed

# deterministic validation of internal links in the two changed Markdown files
# passed

git diff --check
# passed
```

The local macOS toolchain was available, so the relevant Swift test ran. The
EEG suite exercised its existing synthetic contract coverage only; no physical
recording, model download, external worker, or local open-weight model ran.

## Commit Plan

One implementation commit is appropriate because the R0 validator, R1/R2/R3
orchestration, metadata-only writer, configuration, noninterference auditor,
decision-register validator, and synthetic contract test form one atomic
fail-closed boundary. A second documentation/governance commit contains the
decision-register JSON schema, quarantine migration note, architecture guide,
and this report.

## Final Disposition

```yaml
status: ready_for_local_open_weight_smoke_test
science_status: pipeline_only
decision: insufficient_evidence
promotion_status: not_eligible
live_control: false
```
