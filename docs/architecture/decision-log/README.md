# Decision log — number registry

ADR numbers are allocated repository-wide, but ADR *files* are not all stored in
this directory, and some numbers are reserved by code citations before a file
exists. Scanning `docs/architecture/decision-log/` therefore under-reports which
numbers are taken. This registry is the authoritative allocation list; check it
before claiming a number.

| Number | Allocation | File |
|---|---|---|
| ADR-001 | Single-owner `EEGStreaming` with multicast fan-out | `ADR-001-single-owner-eeg-streaming.md` |
| ADR-002 | Deterministic replay as the validation backbone | `ADR-002-deterministic-replay.md` |
| ADR-003 | Runtime separation — Core ML on ANE, MLX isolated to `BCILLM` | `ADR-003-runtime-separation.md` |
| ADR-004 | **Duplicated — requires reconciliation.** Two files share this number | `ADR-004-privacy-first-acquisition.md` and `ADR-004-sentence-embedder-backend-contract.md` |
| ADR-005 | Local interaction logging is not telemetry | `ADR-005-local-interaction-logging.md` |
| ADR-006 | JEPA transition capture is a separate, explicit local data set | `ADR-006-jepa-transition-capture.md` |
| ADR-007 | World Model MPC demo — off-by-default, synthetic-task-only | `ADR-007-world-model-demo.md` |
| ADR-008 | Opus/Sonnet co-development loop and mode-progression ladder | `ADR-008-opus-sonnet-codev-loop.md` |
| ADR-009 | **Reserved: pluggable generation runtime.** Cited as normative in ~45 places across `Sources/BCICloudBridge/`, `Sources/BCICore/Protocols/`, and `Package.swift`, but **no file exists yet** | *(absent — owed)* |
| ADR-010 | **Rust Compute Engine.** Reserved on another branch — see below | not present on this branch |
| ADR-011 | Offline EEG encoder artifact boundary | `ADR-011-offline-eeg-encoder-artifact-boundary.md` |
| ADR-012 | **Reserved (deferred): distributed-edge deployment topology** — see below | *(not written)* |

### ADR-012 reservation

Reserved for a distributed-edge deployment topology (for example an
`batman-adv` mesh of Raspberry Pi nodes running the offline encoder jobs). It
is deliberately **outside W0–W7**: it is a deployment question, not part of the
encoder/fusion/policy boundary, and `ADR-011` commits to an offline artifact
boundary with no streaming or IPC.

Open questions it must answer before any adoption:

```text
mesh transport integrity      — what a dropped or reordered packet means for a window
packet-loss semantics         — whether a partial window is rejected or reconstructed
cross-node clock provenance   — how window timestamps are established across nodes
```

None of these are addressed by the current capture-integrity contract, which
assumes a single recording host.

### ADR-010 reservation

Recorded as plain metadata rather than a link, because the file does not exist
on this branch and a relative link would not resolve:

```text
ADR-010
Status: reserved on research/rust-workspace
Title: Rust Compute Engine
Path on that branch:
  docs/architecture/rust-compute-engine/ADR-010-rust-compute-engine.md
Present in current branch: no
```

## Known defects in the numbering

1. **ADR-004 is duplicated.** Flagged in `docs/reviews/code-review-2026-07-19.md:63`, which proposes renumbering the later (sentence-embedder) file. That remedy competes for a free number; resolve it against this registry rather than picking the next integer.
2. **ADR-009 is cited but absent.** The five invariants attributed to it are recorded in `docs/seeds/seed-004/architecture.json`. Until the file exists, those citations point at nothing a reader can open.
3. **ADR-010 is not in this directory.** It is the reason this registry exists: a `ls docs/architecture/decision-log/` would show 010 as free when it is not.
4. `docs/architecture/benchmark-governance.md` is cited by `ADR-009`-adjacent code comments and also does not exist.

## Allocating a number

1. Read this table, not the directory listing.
2. Take the lowest number not listed above.
3. Add the row here in the same commit that adds the ADR file.
4. If the ADR lives outside this directory, say so in the File column.

Format and worthiness criteria are in `CONTRIBUTING.md`. Existing files use two
shapes: a seven-section form (ADR-001–005) and a four-section form
(ADR-006–008: `Context`, `Decision`, `Consequences`, `Explicitly not decided here`).
