# State Reconstruction Goal 0

> Status: Draft (2026-07-22). This is the first executable
> science artifact for the Julia science workflow. It prepares
> telemetry for later Julia analysis but is not part of the
> application runtime.

## Goal

```text
/goal
Reconstruct one soak as a trajectory through measured state space.
```

This comes before ODEs, stability analysis, bifurcation diagrams,
and parameter estimation. If telemetry cannot be represented as a
coherent trajectory, continuous dynamical models are premature.

## Tool

`Scripts/reconstruct_state_trajectory.py` consumes dialectical turn
JSONL telemetry and emits:

- JSON: reproducible trajectory artifact with schema, rows, and
  diagnostics.
- CSV: notebook-friendly state vector table for plotting and Julia
  ingestion.

Example:

```bash
python Scripts/reconstruct_state_trajectory.py \
  --input SoakRuns/soak-002-20260721-220848/runs/F_qwen15b.jsonl \
  --output /tmp/F_qwen15b-trajectory.json \
  --csv /tmp/F_qwen15b-trajectory.csv \
  --pretty
```

## State Axes

The initial state vector is grounded in existing
`DialecticalTurnEvent` telemetry:

```text
[
  coherence,
  resonance,
  novelty,
  semantic_energy,
  continuation_pressure,
  tension,
  margin,
  selection_temperature,
  gloss_scalar,
  self_similarity
]
```

The first four axes come from the resolved candidate when a turn
speaks or synthesizes. Silent turns use the highest-potential
candidate as the field's unresolved local basin. This keeps the
trajectory defined even when the system preserves tension by saying
nothing.

`continuation_pressure` is a derived telemetry proxy:

```text
1 - normalized_entropy(softmax(candidate_potentials / selection_temperature))
```

It is high when one basin dominates and low when the candidates
remain evenly balanced.

## Falsification Gate

The trajectory is marked `not_representable` when any Goal 0 gate
fails:

- Fewer than three turns.
- Mean state completeness below 0.75.
- Fewer than two active axes.
- No measurable movement through normalized state space.

This does not falsify NeuralCompose. It falsifies the proposed
state representation for that run.

## Promotion Rule

Only a `representable` trajectory should move to the next scientific
stage:

```text
telemetry
  -> state reconstruction
  -> trajectory analysis
  -> dynamical model
```

Rust remains out of scope until later models predict held-out
telemetry with enough evidence to justify a deterministic production
kernel.
