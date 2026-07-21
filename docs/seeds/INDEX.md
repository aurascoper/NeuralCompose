# Session seed index

The version chain. Newest last. Each snapshot is immutable once committed; a new
snapshot supersedes it. See [`README.md`](README.md) for the schema and the
co-development loop.

| Snapshot | Date | Rung | arch / research / runtime versions | Note |
|---|---|---|---|---|
| [seed-001](seed-001/SEED.md) | 2026-07-19 | Focused+Dialectical (waking) | 1 / 1 / 1 | First seed. Sonnet-5 runtime validated; waking register + autostart landed; live Muse-S session + telemetry refresh pending. |
| [seed-002](seed-002/SEED.md) | 2026-07-21 | Reflective (waking) | 2 / 2 / 3 | The Reflective Witness — a non-voiced introspective observer (`WITNESS.md`); reflective/reflexive instrumented as two metrics (`witnessDistance` / `selfSimilarity`), not one dial. Focused-vs-Reflective session pair pending. |
| [seed-003](seed-003/SEED.md) | 2026-07-21 | Reflective (validated) → Contemplative next | 3 / 3 / 5 | Clean hand-off after three PRs merged: the voice de-robotify arc (Personal Voice + `neuralcompose://` Siri scheme, #14), the Witness shipped (#15), and the `dialectic-session` harness that **live-validated** reflective-vs-reflexive (#16, Focused `witness_attempts=0` vs Reflective `=3`). Open decision: run the harness on the Contemplative rung. |
