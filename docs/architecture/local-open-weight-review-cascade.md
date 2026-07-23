# Local Open-Weight Review Cascade

`Scripts/local_open_weight_review.py` is a local-only engineering-review
subsystem. It turns an already quarantined corpus into metadata-only review
receipts. It is not an experiment runner, a scientific adjudicator, a training
pipeline, or an application-control path.

It preserves the quarantine disposition in
[Dialectic Corpus Quarantine](dialectic-corpus-quarantine.md): review material
is permanently development-only and ineligible for encoder, policy, or science
evaluation.

## Cascade

| Stage | Role | Boundary |
| --- | --- | --- |
| R0 | deterministic validator | accepts only complete, citation-valid, non-leaking structured findings |
| R1 | configured local proposer | makes bounded findings for one stateless chunk |
| R2 | configured local reviewer | retries the original chunk with R0 error codes only |
| R3 | configured local Gemma-family critic | manual, advisory adjudication only; never automatic and never overrides R0 |
| R4 | human and evidence gate | required for policy, experiment, scientific, and promotion decisions |

The tracked [default configuration](../../configs/local-open-weight-review-v0.json)
names local Qwen models as values, not as code-path assumptions: `qwen3:0.6b`
for R1, then `qwen3:4b` and `qwen3:1.7b` for bounded R2 attempts. An operator
may provide a different versioned configuration. R3 is disabled by default and
can only be invoked through the explicit adjudication API with a human request.

Only the Ollama-compatible loopback HTTP adapter and a deterministic mock
adapter exist today. An MLX adapter is intentionally deferred until the
repository has a stable, local MLX service interface; no new MLX dependency is
introduced by this subsystem.

## Fail-Closed Contract

Before any request, the source must have the complete quarantine disposition,
match the SHA-256 in its quarantine report, and remain unchanged for the full
review. The backend must be explicitly local and use a loopback endpoint or a
Unix socket classification. LAN, VPN, container-host, cloud, and arbitrary
remote URLs are rejected. Loopback is only backend-boundary evidence: the
operator separately attests network isolation and confinement of prompt and
response logging to an ignored local directory.

Chunks have canonical source-line IDs, use a versioned size and overlap, and
mark overlap records. Each invocation receives the same frozen system prompt.
No model has cross-chunk conversation memory. R2 receives the original chunk
and machine-readable R0 error codes, never an earlier raw response.

R0 accepts only a complete JSON array of known finding types with finite
confidence, nonempty evidence, exact chunk-local citations, and at least one
new-record citation. It does not repair invented citations or accept a partial
response. A bounded five-token source-overlap detector blocks substantial text
reproduction in synthetic tests. This detector is a useful guardrail, not proof
that an artifact contains no private text.

The metadata-only summary counts accepted findings, source-line references,
confidence buckets, conflicts, and rejection receipts. It receives no raw
records and cannot infer a new semantic claim, create an EEG hypothesis, or
recommend a model or policy change.

## Local Use

The dry run builds and validates in-memory chunk envelopes without starting a
model or writing prompts:

```sh
python3 Scripts/local_open_weight_review.py \
  --source <quarantined-local-jsonl> \
  --quarantine-report <local-quarantine-report> \
  --configuration configs/local-open-weight-review-v0.json \
  --dry-run
```

An operator may run a bounded local smoke test only after verifying the local
runtime's retention settings and choosing an ignored local artifact directory:

```sh
python3 Scripts/local_open_weight_review.py \
  --source <quarantined-local-jsonl> \
  --quarantine-report <local-quarantine-report> \
  --configuration configs/local-open-weight-review-v0.json \
  --backend-url http://127.0.0.1:11434 \
  --artifact-directory <ignored-local-review-directory> \
  --attest-network-isolation \
  --attest-prompt-response-logging-confined
```

This command is documentation only. It is never executed by repository tests
or CI. The implementation does not download models, create embeddings, update
weights, or retain raw prompts or responses. The manifest records unavailable
backend facts as `null` or `not_reported` rather than inventing provenance.

## EEG Noninterference

`Scripts/local_review_noninterference.py` checks metadata-only artifacts for
the required separation: dialogue source and content hashes are absent from EEG
artifacts and model inputs; review findings are absent from the experiment
configuration; EEG window hashes are absent from review prompt metadata; and no
shared training buffer, dialogue embedding, or dialogue-derived weight update
exists.

The review subsystem and the structured EEG state bridge may share only JSON,
hash, validation, manifest, and disposition patterns. They share no data,
embeddings, labels, model inputs, training buffers, configuration, or scientific
results. The bridge stays `shadow_only: true`, `live_control: false`, and
`promotion_status: not_eligible`.

## Research Governance

The JSON schema at
[Research Decision Register](../scoping/research-decision-register.schema.json)
records whether a future method is deferred, study-only, or eligible for a
separately registered experiment. It always requires
`runtime_dependency_authorized: false`; a register entry cannot add a package,
model, runtime route, app feature, or promotion decision.

The four-pass order in the
[EEG mathematics, physics, and methods scope](../scoping/eeg-mathematics-physics-methods-scope.md)
is unchanged: Pass 1 encoder evidence, Pass 2 registered forward/inverse
foundations, Pass 3 decision-changing methods, then Pass 4 structured-state
shadow policy. The immediate EEG action remains the first frozen physical Muse
capture, not a review-model, policy, or mathematics expansion.
