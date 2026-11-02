# NeuralCompose Interaction Logs and Autobank Fixtures (2026-11-01 / 2026-11-02)

`[ENGINEERING TELEMETRY - QUARANTINED FROM SCIENTIFIC CORPUS PER ADR-005]`

This directory contains the synchronized `2026-11-01` and UTC midnight rollover `2026-11-02` interaction telemetry logs, `claude-mind` autobank manifests, Golden Recording reconciliation synthesis, Verified Claims Memo (`"Basilisk as M7 planetary reference.md"`) audit records, and Turn L112 non-recursive self-improvement poller synthesis exported from `~/Documents/NeuralCompose/InteractionLogs/`:

- `dialectic-turns-2026-11-01.jsonl` (156 privacy-scrubbed turns across runs `23BF5B65`, `F518FBE3`, `B5C2F73F`, `A5945350`, `2E7E8987`, `27738095`, `1B1B45AE`, `10308A51`, `F418DE55`, and `1824FBDB`)
- `dialectic-turns-2026-11-02.jsonl` (11 UTC midnight rollover turns `L1..L11`, `index: 19..29`, covering `1e3` `SPICE.jl` km-to-m unit conversion boundary `convert_spice_state_to_basilisk_si(raw_state_km)` vs `pro_factor`, `Neurospora` in `SmallModularBioReactors.jl` + `SPICE.jl` + `Basilisk` + `Vizard`, `OpenFOAM` CFD runs, and `MATLAB` / `Simulink` / `Simscape` Student Suite toolboxes)
- `dialectic-autobank-2026-11-01.jsonl` (125 quality-warranted spoken turns passing `Scripts/memory-gate.py` and `DialecticalMemory.evaluateAutobankWarrant`, including `warranted_high_potential` rescues for `L145` and `L151..L153`)
- `dialectic-autobank-2026-11-02.jsonl` (11 quality-warranted spoken turns from the `2026-11-02` UTC rollover log, including `warranted_high_potential` rescue for `L6`)
- `autobank-manifest-2026-11-01.jsonl` (168 idempotent `mcp__claude-mind__remember` payloads: 136 `app-dialectic` across `2026-11-01` and `2026-11-02`, 28 `world-model`, 3 `golden-reconcile` including `canonical:basilisk-as-m7-planetary-reference-confirmed`, 1 `report`)
- `autobank-manifest-2026-11-02.jsonl` (14 idempotent `mcp__claude-mind__remember` payloads for `2026-11-02` rollover turns + `golden-reconcile`)
- `prosody-trace-2026-11-01.jsonl` (146 prosodic contour traces) and `prosody-trace-2026-11-02.jsonl` (11 prosodic contour traces)
- `health-2026-11-01.jsonl` (964 runtime health and Muse S channel quality snapshots)
- `equifinal-dialectic-turns.jsonl` (1448 deduplicated equifinal dialectical decision chain records through `dec_1111` synced with `multica_channel.jsonl`)
- `golden-reconciliation-synthesis.json` (Golden Recording `golden_20260710-141352` 4-channel RMS baseline + live Muse BLE reconciliation program synthesis)
- `poller-self-improvement-synthesis-v2.json` (Turn L112 non-recursive Plasticity Shell poller synthesis covering all 156 `2026-11-01` turns + 11 `2026-11-02` rollover turns, 14 ASR phonetic recovery rules with 59 recoveries applied, `basilisk_m7_planetary_reference_verified_audit`, `utc_midnight_rollover_2026_11_02_audit`, and sanitized macOS `sysctl vm.swapusage` + `vm_stat` 16-32 GB compressor/swap telemetry)
- `INTERACTION_LOGS_MANIFEST_2026-11-01.json` (SHA-256 digests and ADR-005 quarantine metadata for all 12 synchronized files)

## Governance Invariants

1. **Corpus Quarantine (`ADR-005`)**: Every file in this directory has `eligible_for_science: false` and `eligible_for_encoder_training: false`.
2. **Privacy Hygiene**: All repository copies are scrubbed of private household transcripts and personal identifiers (`fix(privacy,dialectic)`).
3. **Typography Invariant**: Strictly zero em-dashes and zero en-dashes across all repository JSONL/JSON fixtures, manifests, and documentation.
