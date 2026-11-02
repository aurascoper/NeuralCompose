# Trajectory Analysis Goal 1

> Status: Draft (2026-07-22). This is the second executable
> science artifact for the Julia science workflow. It consumes a
> reconstructed state trajectory and asks whether any candidate
> dynamical hypothesis deserves a Julia model.

## Goal

```text
/goal
Analyze reconstructed trajectories for falsifiable evidence of
candidate dialogue dynamics.
```

This comes after state reconstruction and before ODEs. Goal 1 does
not estimate parameters, solve differential equations, or promote
anything to Rust. It asks whether the measured trajectory contains a
model-free pattern strong enough to justify a mathematical model.

## Tool

`Scripts/analyze_state_trajectory.py` consumes the JSON emitted by
`Scripts/reconstruct_state_trajectory.py`.

Example:

```bash
python Scripts/reconstruct_state_trajectory.py \
  --input SoakRuns/soak-002-20260721-220848/runs/F_qwen15b.jsonl \
  --output /tmp/F_qwen15b-trajectory.json \
  --csv /tmp/F_qwen15b-trajectory.csv \
  --pretty

python Scripts/analyze_state_trajectory.py \
  --input /tmp/F_qwen15b-trajectory.json \
  --output /tmp/F_qwen15b-analysis.json \
  --pretty
```

The analysis artifact has schema
`state-trajectory-analysis-v0` and records the question,
hypotheses, operationalized metrics, falsification flags,
decision, and next scientific stage.

## Candidate Hypothesis

The first candidate hypothesis is intentionally small:

```text
Continuation pressure creates stable attractors.
```

The script splits that claim into two testable pieces.

### H1: Local Attractor Proxy

```text
The reconstructed dialogue trajectory approaches a local attractor.
```

Operationalization:

- The late trajectory window has lower normalized step distance
  than the early window.
- The late trajectory window has lower normalized radius than the
  early window.

This is not proof of an attractor. It is a model-free proxy that
can reject trajectories that expand, wander, or fail to stabilize.

### H2: Continuation Pressure Stabilizes Motion

```text
Higher continuation pressure predicts smaller next-step movement.
```

Operationalization:

- `continuation_pressure(t)` is negatively correlated with
  normalized movement from `t` to `t + 1`.
- High-pressure turns have lower next-step movement than
  low-pressure turns.

This keeps the hypothesis falsifiable. A trajectory can converge
without continuation pressure being the driver, and continuation
pressure can be measurable without stabilizing the trajectory.

## Falsification Gate

The combined hypothesis is marked:

- `not_testable` when Goal 0 did not produce a representable
  trajectory or there are too few turns/samples.
- `rejected` when either operationalized claim fails.
- `supported` only when the local-attractor proxy and continuation
  pressure stabilization claim both pass.

The default thresholds are intentionally conservative and should be
reported with every artifact:

```text
min_turns = 6
max_late_early_step_ratio = 0.80
max_late_early_radius_ratio = 0.80
min_pressure_samples = 6
min_negative_correlation = 0.25
```

## Promotion Rule

A supported Goal 1 result promotes only the question:

```text
state reconstruction
  -> trajectory analysis
  -> Julia dynamical-model candidate
```

It does not promote code into the application runtime and does not
justify a Rust kernel. Rust appears only after later Julia or
reference-model work predicts held-out telemetry with enough
evidence to justify deterministic production implementation.

Rejected results are valuable. They narrow the search space by
showing that either the state representation, the continuation
pressure proxy, or the attractor claim needs revision.
