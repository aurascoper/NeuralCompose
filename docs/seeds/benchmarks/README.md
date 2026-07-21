# Session benchmarks

Canonical evaluation inputs for the dialectical engine. Each
benchmark is a versioned, immutable file under this directory; future
benchmarks are added (benchmark-002, …), never edits.

## Index

| Benchmark | Topic | Authored | Status |
|---|---|---|---|
| [benchmark-001-grounding.txt](benchmark-001-grounding.txt) | grounding / "what makes a dialogue honest" | 2026-07-21 | canonical v1; first-drafted on `worldmodel/overnight-transform-ab@e1eb7f4`; the cross-provider regression suite for the GenerationRuntime work in `feature/pluggable-generators` |

## Usage

A benchmark is a list of <n> short lines; the dialectic engine feeds
them to the script-listener one per turn and emits one
`DialecticalTurnEvent` per turn. Cross-provider runs MUST use the
identical benchmark bytes; only the runtime, model, and generation
parameters may differ. See `docs/architecture/benchmark-governance.md`
(pending) and ADR-009 invariant #5.
