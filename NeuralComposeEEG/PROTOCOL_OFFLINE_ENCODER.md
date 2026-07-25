# Offline encoder job protocol (W2)

Status: proposed, D0 contract only. No job runner is implemented.

This is the boundary between a provenance-bound recording and an immutable
`nc-eeg-encoder-state-v0` artifact. It is **file-based by decision**
(`ADR-011`): the application never launches an encoder, so there is no
subprocess lifecycle, no IPC, no daemon, and no cancellation channel inside the
app. Job execution is CLI- or operator-driven, outside the app process.

It extends the file-handoff shape already used by `run_eegpt_fold_worker.py`
and `run_bendr_fold_worker.py` rather than introducing a second mechanism.

## Lifecycle

```text
request manifest
  → external CLI / operator execution
  → temporary output  (job-owned scratch path)
  → validation        (schema + provenance + geometry)
  → atomic rename     (single publication point)
  → immutable result manifest
```

Publication is the rename. Nothing downstream may observe a partially written
artifact, and a published artifact is never edited in place — a correction is a
new run with a new run ID.

### Atomic publication, precisely

`rename(2)` is atomic only *within* a filesystem. The protocol therefore
requires the temporary path and the final path to share one parent directory,
and so one filesystem:

1. Create the temporary output **in the destination directory**, not in a
   system temp dir.
2. Write records to a temporary filename (e.g. `.<run_id>.jsonl.partial`).
3. Flush and close the handle.
4. Validate the completed file — schema, geometry, provenance, record count.
5. Compute the artifact and manifest hashes.
6. Publish by same-filesystem rename to the canonical name.

Additional rules:

- An existing canonical destination is **never silently overwritten**. A
  collision is `publication_failed`.
- Symlinks, and any path escaping the approved output root after resolution,
  are rejected.
- After cancellation or failure, partial JSONL output remains non-canonical:
  it keeps its temporary name and is never a replay input.

## Request manifest

```json
{
  "schema_version": "nc-eeg-encoder-job-request-v0",
  "request_id": "req-2026-07-24-0001",
  "encoder": {
    "model_id": "eegnet",
    "model_revision": "…",
    "checkpoint_kind": "pinned_upstream_checkpoint",
    "checkpoint_sha256": "…",
    "adapter": "…",
    "adapter_sha256": "…"
  },
  "input": {
    "source_type": "deterministic_synthetic_fixture",
    "recording_sha256": "…",
    "window_manifest_sha256": "…",
    "rewindowing_config_sha256": "…",
    "capture_manifest_sha256": null,
    "integrity_report_sha256": null
  },
  "output": {
    "schema_version": "nc-eeg-encoder-state-v0",
    "max_records": 100000,
    "max_bytes": 268435456
  }
}
```

`source_type` follows the same discriminated union as the output schema. For
`physical_recording_replay`, `capture_manifest_sha256` and
`integrity_report_sha256` are **required and non-null**; a request that names
physical input without them is rejected before execution.

## Result manifest

```json
{
  "schema_version": "nc-eeg-encoder-job-result-v0",
  "request_id": "req-2026-07-24-0001",
  "run_id": "run-…",
  "request_sha256": "…",
  "completion_status": "succeeded",
  "record_count": 6,
  "records_sha256": "…",
  "worker_run_manifest": { "…": "see below" },
  "shadow_only": true,
  "live_control": false,
  "promotion_status": "not_eligible"
}
```

`request_id` identifies *what was asked*; `run_id` identifies *one attempt*.
Re-running a request produces a new `run_id` and must produce an identical
`records_sha256` — that equality is the determinism check.

## Provenance

`worker_run_manifest` reuses `_validate_external_worker_run_manifest`
(`src/neuralcompose_eeg/contracts.py`) unchanged — eight non-empty strings plus
an integer seed:

`platform`, `accelerator`, `accelerator_memory`, `python_version`,
`torch_version`, `cuda_or_mps_version`, `available_quota`, `git_commit`, `seed`

`"unavailable"` is a legal value; a missing key is not. Do not add a parallel
provenance vocabulary.

## Typed completion status

| Status | Meaning | Replayable |
|---|---|---|
| `started` | Run began; output is non-canonical | no |
| `completed` | All records validated and published | **yes** |
| `cancelled` | Operator interrupted | no |
| `model_load_failed` | Weights unreadable or architecture mismatch | no |
| `checkpoint_mismatch` | Checkpoint digest ≠ request | no |
| `invalid_output` | A record failed schema, geometry, or provenance | no |
| `nonfinite_output` | NaN/±Inf in probabilities, uncertainty, or embedding | no |
| `publication_failed` | Rename failed, or the destination already existed | no |

**Only `completed` may be replayed.** There is no partial-success status: a run
either publishes every record or publishes nothing.

## Rejection rules

- **Partial output.** Records are written to scratch and counted; a count
  mismatch against the window manifest rejects the run.
- **Path traversal.** Every path is resolved and must remain inside the
  declared artifact root. `..` segments, absolute paths, and symlinks that
  escape the root are rejected. Follows the containment idiom already used by
  `_resolve_contract_path` in `fusion_contract.py`.
- **Size limits.** `max_records` and `max_bytes` are declared in the request
  and enforced during writing, not after.
- **Non-finite values.** Rejected at validation; never clamped or renormalized.
- **Checkpoint mismatch.** The loaded checkpoint's digest must equal the
  request's. No substitution, and no fallback to a different encoder.
- **Window geometry.** Every record must carry `window_samples: 1024`,
  `stride_samples: 256`, the pinned channel order, and
  `live_two_second_window_used: false`. The app's 2 s live window is not a
  legal input; padding or duplicating it to 1024 samples is a defect.
- **Clock fields.** For physical replay, window timestamps follow the
  capture-integrity clock contract. They may never be inferred from filenames
  or file modification times.

## Determinism

A published artifact must satisfy: same request manifest + same checkpoint +
same seed ⇒ byte-identical `records_sha256`. This mirrors the existing
guarantee in `test_fusion_contract.py::test_committed_artifacts_match_clean_regeneration`.

## What this protocol does not cover

In-process execution, streaming or incremental windows, subprocess supervision,
retry or backoff policy, concurrent job scheduling, and automatic checkpoint
download. All are out of scope by `ADR-011`.
