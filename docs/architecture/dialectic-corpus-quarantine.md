# Dialectic Corpus Quarantine

Private `dialectic-turns-*.jsonl` files under
`~/Documents/NeuralCompose/InteractionLogs/` are local engineering artifacts,
not scientific source data. This boundary applies even when a file is trusted,
replayable, or useful for debugging.

## Disposition

Every derived artifact carries this exact disposition:

```json
{
  "corpus_role": "engineering_replay_only",
  "development_only_permanent": true,
  "eligible_for_encoder_training": false,
  "eligible_for_encoder_evaluation": false,
  "eligible_for_policy_training": false,
  "eligible_for_policy_evaluation": false,
  "contains_private_dialogue": true,
  "cloud_exposure_allowed": false
}
```

Local engineering may inspect the raw file for parser recovery, chronological
reconstruction, UI replay, turn reconciliation, dialogue-state debugging, or
future event-manifest development. It must not use dialogue content to create
EEG labels, encoder features, normalization, splits, thresholds, model
selection, held-out metrics, or policy-training data.

## Local-Only Derivatives

The source remains byte-for-byte untouched. Produce only ignored local
derivatives:

```sh
python3 Scripts/quarantine_dialectic_corpus.py \
  --input "$HOME/Documents/NeuralCompose/InteractionLogs/dialectic-turns-2026-07-22.jsonl" \
  --parse-report "$HOME/Documents/NeuralCompose/InteractionLogs/local-manifests/dialectic-parse-report-2026-07-22.json" \
  --events-output "$HOME/Documents/NeuralCompose/InteractionLogs/local-manifests/dialectic-events-2026-07-22.jsonl"
```

The parse report records the source SHA-256, byte size, capture date inferred
only from the filename, valid and malformed line counts, parser version,
backend identities, and rejection reasons. The event stream contains no text
or embeddings: source-line-based IDs, the non-unique original turn index,
structural outcome, candidate count, a digest and byte count of all
content-bearing fields, and explicit missing provenance.

The parse report preserves physical source-line order, records duplicate or
non-monotonic original turn indexes, and reports timestamp monotonicity as
unavailable when the source event did not record a timestamp. These are replay
diagnostics, not temporal-alignment evidence.

`DialecticalTurnEvent` records neither a timestamp nor a speaker role. The
metadata stream writes `timestamp_unix: null` and `speaker_role:
"unspecified"`; it does not synthesize either value. A possible EEG-session
crosswalk may be recorded, but its alignment is always
`recorded_not_scientifically_enabled` and it is never consumed by
`EXP-NC-EEG-ENC-001`.

## Cloud And Science Boundary

Never upload the raw file to a cloud agent. Cloud contract work may use the
event schema, a parse report, hashes/counts, and synthetic malformed fixtures.
The private source must stay outside Git-tracked artifacts.

Inspection makes the file development-only. Any future EEG/dialogue coupling
requires a separately preregistered post-encoder experiment with a frozen
structured-state schema, temporal alignment rules, whole-session splits,
privacy rules, and unseen confirmation sessions. See
[the EEG methods scope](../scoping/eeg-mathematics-physics-methods-scope.md)
and [ADR-005](decision-log/ADR-005-local-interaction-logging.md).

## Local Semantic Engineering Review

An already quarantined source may be inspected by a local Qwen 0.5B-class
model for bounded engineering review. This is not a scientific analysis and
does not change the disposition above. The reviewer accepts only a loopback
Ollama endpoint and a local `qwen2.5:*` model; remote or cloud-backed model
identities are rejected.

Before a run, the operator must verify that the local runtime will not retain
prompt text outside this quarantine directory, then attest to that state on
the command line:

```sh
python3 Scripts/review_quarantined_dialectics.py review \
  --input "$HOME/Documents/NeuralCompose/InteractionLogs/dialectic-turns-2026-07-22.jsonl" \
  --parse-report "$HOME/Documents/NeuralCompose/InteractionLogs/local-manifests/dialectic-parse-report-2026-07-22.json" \
  --findings-output "$HOME/Documents/NeuralCompose/InteractionLogs/local-manifests/dialectic-local-review-2026-07-22.jsonl" \
  --run-manifest-output "$HOME/Documents/NeuralCompose/InteractionLogs/local-manifests/dialectic-local-review-run-2026-07-22.json" \
  --prompt-logging-status verified_disabled
```

The review is stateless: fixed 16-valid-record chunks, two-record overlap,
temperature `0.0`, seed `42`, no embeddings, and no weight updates. The tool
itself persists neither raw prompts nor raw responses; the external runtime is
used only after the operator verifies its retention behavior. It accepts only
bounded JSON findings that cite source lines in their own chunk, use an allowed
engineering category, and do not contain verbatim private content.

Aggregate the metadata-only review stream without reopening the raw corpus:

```sh
python3 Scripts/review_quarantined_dialectics.py aggregate \
  --findings-input "$HOME/Documents/NeuralCompose/InteractionLogs/local-manifests/dialectic-local-review-2026-07-22.jsonl" \
  --output "$HOME/Documents/NeuralCompose/InteractionLogs/local-manifests/dialectic-local-review-aggregate-2026-07-22.json"
```

The aggregate reports issue categories, counts, affected source lines,
conflicting findings, confidence buckets, and cross-chunk recurrence. Any
future policy or prompt affected by this review is development-only and must
be evaluated on fresh, protocol-defined sessions that have not been inspected.
