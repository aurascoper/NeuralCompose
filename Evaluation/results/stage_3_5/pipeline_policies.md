# Stage 3.5-P: Pipeline Policy Comparison

Evaluated: 2026-07-16T23:53:24.777779+00:00

**Methodology caveats** — see `run_stage_3_5.py`'s module docstring for the full reasoning: `auto:*` role resolution and Adaptive's routing-bucket assignment are methodological choices made by this script, not read from a canonical spec. The embedding routing rule's `uncertain -> confidence_gated` branch has no real confidence signal to gate on yet (same gap `3.5-E` is pre-registered to investigate) and is resolved as a `mid_tier` proxy instead.

Prompt category buckets (of 27 corpus prompts): short_command=4, technical=3, uncertain=20

## Resolved policies

| Policy | Quality | Latency (s) | Memory (MB) |
|---|---|---|---|
| Fast | 0.2659 | 1.232 | 1114.5 |
| Balanced | 0.7009 | 2.502 | 1646.1 |
| Quality | 1.0000 | 2.291 | 3985.2 |
| Adaptive | 0.8431 | 3.010 | 3910.2 |

**Pareto frontier:** Fast, Balanced, Quality, Adaptive

## Success criterion: Adaptive mode is Pareto-optimal OR within 5% of the best fixed mode on every axis

**Verdict: PASS** — Adaptive is on the Pareto frontier

