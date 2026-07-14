# Throughput Discrepancy Investigation

## Finding

The embedding leaderboard reports MiniLM at 1980 emb/s, but the stored
benchmark.json reports 1015 emb/s.

## Root cause

Two different benchmark runs produced different throughput numbers. The
streaming benchmark ran first and recorded 1980 emb/s in the
leaderboard. A subsequent non-streaming benchmark run overwrote
benchmark.json with a lower number (1015 emb/s, batch size 128).

## Evidence

- `benchmark.json` timestamp: 2026-07-14T04:59:24 UTC (July 13 23:59
  local)
- `benchmark.json` batch_metrics: batch 128 produced 1015 emb/s
- `leaderboard.json` embeddings_per_second: 1980 emb/s (from the
  streaming benchmark run, which is no longer on disk)

## Measurement methodology

The embedding benchmark measures throughput at multiple batch sizes (1,
8, 32, 128). The `embeddings_per_second` field in benchmark.json is the
best batch size result (typically 128). The streaming benchmark reads
this field directly.

The discrepancy is likely caused by:

1. The streaming benchmark ran when the system was warm (models already
   in page cache), producing higher throughput.
2. The subsequent run was cold (models evicted), producing lower
   throughput.
3. No other batch size or measurement methodology difference was found.

## Resolution

Until the benchmark is re-run under controlled conditions, throughput
comparisons across models should use the leaderboard values (which were
all measured in the same streaming benchmark session) rather than
individual benchmark.json values (which may be from different runs).

## Future methodology

Future benchmarks should:

1. Record whether the measurement is warm or cold.
2. Run all models in a single session to ensure consistent system state.
3. Store the streaming benchmark's per-model benchmark.json separately
   (not overwrite the canonical benchmark.json).
4. Document the batch size used for the reported throughput.
## Resolution — 2026-07-14 (controlled reproducibility rerun)

A controlled rerun on a quiescent machine (07:10 local, no concurrent
benchmarks or builds; `Evaluation/results/repro/all-MiniLM-L6-v2/python/`,
provenance-stamped) measured **2538 emb/s** (warm encode 34.5 ms) against
the canonical checkpoint's 1015 emb/s (95.4 ms) — the rerun does NOT
reproduce the canonical throughput and is 2.5× faster. It also does not
match the orphaned leaderboard value of 1980 emb/s, which lies between
the two.

Every quality metric reproduced within |Δ| ≤ 0.0008 in the same run pair
(retrieval and nn-consistency identical, stability Δ0.00073 — see
`Evaluation/results/repro/repro_report.md`).

Conclusion: MiniLM throughput on this hardware varies by more than 2×
with machine load and thermal state, while quality metrics are robust to
it. The canonical 1015 was measured mid-campaign with other work on the
machine; the orphaned 1980 plausibly came from an intermediate load
state whose source JSON was lost. The leaderboard now re-derives
mechanically from the on-disk checkpoint (1015), which the validator
enforces. Absolute embeddings-per-second values in this evidence base
should be read as load-dependent lower bounds; cross-model throughput
comparisons are only meaningful within a single campaign context, and
the quality rankings are unaffected.
