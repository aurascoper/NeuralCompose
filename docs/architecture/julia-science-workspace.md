# Julia Science Workspace

> **Status:** Draft (2026-07-22). This document defines Julia's
> role as an offline scientific companion to NeuralCompose. It
> does not add Julia to the application runtime.

## Purpose

Julia belongs beside NeuralCompose as a scientific laboratory,
not inside NeuralCompose as another production runtime. The Swift
application remains responsible for interaction, UI, orchestration,
and Apple-platform integration. Rust is the target for validated,
deterministic computational kernels. Julia is where mathematical
hypotheses are prototyped, simulated, fit to telemetry, and
visualized before any production implementation is considered.

Mission statement:

```text
NeuralComposeScience exists to transform runtime telemetry into
mathematical understanding.
```

Its practical goal is:

```text
/goal
Develop, falsify, and validate mathematical models that explain
NeuralCompose telemetry, producing reproducible computational
hypotheses that can be promoted to deterministic Rust kernels when
empirically justified.
```

For Julia specifically:

```text
/goal
Discover mathematical structure that predicts the evolution of
NeuralCompose's measured state.
```

The optimization target is scientific throughput:

```text
maximize validated insight / week
```

not runtime throughput. Julia is valuable here because it helps
develop candidate models, reject models that fail observations,
quantify goodness of fit, estimate parameters, and analyze
stability.

The boundary is artifact-based:

```text
Swift interaction
  -> runtime telemetry
  -> JSONL / metrics / experiment artifacts
  -> Julia research workspace
  -> model insight, parameter estimates, plots, papers
```

The avoided path is:

```text
Swift interaction
  -> Julia
  -> speech or UI behavior
```

Julia consumes artifacts. It does not drive the application.

It is explicitly not responsible for UI, LLM orchestration,
prompting, speech, agents, application state, or live interaction
behavior.

## Repository Boundary

The natural home for this work is a separate repository or sibling
workspace:

```text
NeuralComposeScience/
  experiments/
  models/
  ode/
  pde/
  parameter_estimation/
  notebooks/
  papers/
```

That workspace should have no AVFoundation, SwiftUI, SceneKit, app
state, or production speech loop. It is mathematics, simulation,
estimation, and visualization over exported evidence.

## First Responsibility

The first responsibility of `NeuralComposeScience` is not to solve
differential equations. It is to discover an appropriate state-space
representation from telemetry.

The prerequisite question is:

```text
Can one soak run be reconstructed as a coherent trajectory through
a measured state space?
```

If telemetry cannot be represented as a coherent trajectory, ODEs,
stability analysis, bifurcations, and parameter estimation are
premature. The research workflow must stay coupled to measured
evidence rather than assumed dynamics.

## Research Progression

The progression is:

```text
telemetry
  -> state reconstruction
  -> trajectory analysis
  -> dynamical model
  -> parameter estimation
  -> prediction
  -> validation
  -> Rust implementation
  -> Swift runtime
```

Rust only appears after empirical validation. Swift only sees the
validated kernel after the production boundary is justified.

## Modeling Target

Once the state representation is grounded, the first mathematical
modeling target is dialogue as a dynamical system rather than
dialogue as only a sequence of discrete turns.

```text
x(t) -> dx/dt -> trajectory -> attractor
```

That lets a research workspace ask whether a dialogue is converging,
oscillating, moving between attractors, or showing sensitivity to
initial conditions.

## Candidate Model Families

### Dialogue Dynamics

Treat the latent dialogue field as a continuous state trajectory.
Julia packages such as `ModelingToolkit.jl`,
`DifferentialEquations.jl`, and `DynamicalSystems.jl` are useful
only after the state variables, reconstruction method, and
hypotheses are named.

### Field Energy

Existing research terms such as coherence, novelty, resonance, and
continuation pressure can become state variables instead of loose
heuristics. A first model can be intentionally simple:

```text
x = [
  coherence,
  novelty,
  continuation_pressure,
  semantic_energy
]

dx/dt = f(x, parameters)
```

The equations are hypotheses. They are allowed to be wrong; their
job is to become testable.

### Stability Analysis

Once a candidate system exists, Julia can help identify equilibrium
points, stable and unstable regions, attractors, and bifurcations.
That connects directly to long soak observations: instead of only
saying that a model drifted, the research question can become
whether the trajectory crossed a stability boundary.

### Parameter Estimation

Telemetry gives the research loop an empirical anchor:

```text
ResearchHypothesis
  -> run
  -> telemetry
  -> parameter estimation
  -> revised hypothesis
```

Julia is well suited for fitting dynamical models to observed
behavior, then comparing simulated trajectories against recorded
soak runs.

## Learning Sequence

The recommended learning order mirrors the research workflow:

1. Telemetry ingestion and state reconstruction from JSONL and
   metric artifacts.
2. Trajectory analysis over reconstructed state spaces.
3. `ModelingToolkit.jl` for symbolic model construction.
4. `DifferentialEquations.jl` for solving ODE systems.
5. `DynamicalSystems.jl` for attractors, sensitivity, and
   stability analysis.
6. `Optimization.jl` for fitting model parameters.
7. `Makie.jl` for trajectories, phase portraits, and bifurcation
   diagrams.

The purpose is not to read package manuals end to end. The purpose
is to build small, inspectable models around named hypotheses.

## Goal 0

Reconstruct one soak as a trajectory through a state space.

Start by deriving one state vector per turn or time window:

```text
x = [
  coherence,
  novelty,
  continuation_pressure,
  semantic_energy
]
```

The output is a reproducible trajectory artifact and a visualization
that shows whether the selected dimensions form a coherent path
through state space.

The repo-side prototype for this bridge is
`Scripts/reconstruct_state_trajectory.py`; see
`docs/science/state-reconstruction-goal-0.md`. It prepares JSON/CSV
trajectory artifacts for Julia without adding Julia to the runtime.

## Goal 1

Analyze a reconstructed trajectory before choosing a dynamical model.

The first candidate question is:

```text
Does continuation pressure create stable attractors?
```

The repo-side prototype for this falsification gate is
`Scripts/analyze_state_trajectory.py`; see
`docs/science/trajectory-analysis-goal-1.md`. It consumes a Goal 0
trajectory artifact and reports whether the local-attractor proxy and
continuation-pressure stabilization claim are supported, rejected, or
not testable.

A supported Goal 1 result promotes the question to Julia dynamical
modeling. It does not promote code into Swift and does not justify a
Rust kernel.

## First Model Experiment

Only after Goal 0 succeeds, posit a simple first-order nonlinear
system, simulate trajectories, and compare them qualitatively against
one long soak run. The first modeling question is not whether the
equations are correct. The first question is whether any continuous
dynamical model can reproduce the observed shape of the behavior.

Every Julia project should answer exactly one question:

```text
experiment
  -> hypothesis
  -> Julia model
  -> telemetry comparison
  -> reject or promote
```

Example:

```text
Experiment:
Can dialogue trajectories be modeled as a continuous dynamical system?

Hypothesis:
Continuation pressure creates stable attractors.

Julia model:
ODE simulation.

Telemetry:
Compare simulated and reconstructed trajectories.

Decision:
Reject, revise, or promote.
```

Sobolev-style trajectory fitting and ZPD-style intervention policies
can generate future Julia experiments, but they remain hypotheses,
not runtime doctrine. See `docs/science/sobolev-zpd-hypotheses.md`.

## Promotion Path

Julia prototypes should remain reference models until validated:

```text
hypothesis
  -> Julia prototype
  -> validated model
  -> Rust implementation
  -> Swift integration
```

The unhealthy path is:

```text
Julia prototype
  -> shipped application behavior
```

This keeps each language's identity clear:

- Swift: interaction, UI, orchestration, Apple ecosystem.
- Rust: deterministic, production computational kernels.
- Julia: scientific discovery, modeling, simulation, validation.
- Python: training pipelines, JEPA experiments, and ML tooling.

## Roadmap Fit

Julia work can begin in parallel with Rust Phase 0 after
`feature/pluggable-generators` stabilizes. The sequencing is:

1. Merge `feature/pluggable-generators` into `main`.
2. Begin Rust Phase 0 as a deterministic utility crate.
3. Create `NeuralComposeScience/` as a separate Julia research
   workspace.
4. Treat each Julia model as a scientific hypothesis.
5. Reimplement only validated computational kernels in Rust.
