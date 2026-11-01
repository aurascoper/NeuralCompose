# NeuralCompose Interaction Logs and Autobank Fixtures (2026-11-01)

`[ENGINEERING TELEMETRY - QUARANTINED FROM SCIENTIFIC CORPUS PER ADR-005]`

This directory contains the synchronized `2026-11-01` interaction telemetry logs and session-time `claude-mind` autobank manifest exported from `~/Documents/NeuralCompose/InteractionLogs/` for Fable 5.1 (`/boost`, `/migrate-workflows`, and `/teamwork` multi-agent verification):

- `dialectic-turns-2026-11-01.jsonl` (40 lines across runs `23BF5B65`, `F518FBE3`, and `B5C2F73F`)
- `dialectic-autobank-2026-11-01.jsonl` (18 quality-warranted spoken turns passing `Scripts/memory-gate.py` and `DialecticalMemory.evaluateAutobankWarrant`)
- `autobank-manifest-2026-11-01.jsonl` (47 idempotent `mcp__claude-mind__remember` payloads: 18 `app-dialectic`, 28 `world-model`, 1 `report`)
- `prosody-trace-2026-11-01.jsonl` (32 prosodic contour traces)
- `health-2026-11-01.jsonl` (366 runtime health and Muse S channel quality snapshots)
- `equifinal-dialectic-turns.jsonl` (privacy-scrubbed equifinal dialectical decision chain records)
- `INTERACTION_LOGS_MANIFEST_2026-11-01.json` (SHA-256 digests and ADR-005 quarantine metadata)

## Governance Invariants

1. **Corpus Quarantine (`ADR-005`)**: Every file in this directory has `eligible_for_science: false` and `eligible_for_encoder_training: false`.
2. **Privacy Hygiene**: All repository copies are scrubbed of private household transcripts and personal identifiers (`fix(privacy,dialectic)`).
3. **Typography Invariant**: Strictly zero em-dashes and zero en-dashes across all repository JSONL fixtures, manifests, and documentation.
