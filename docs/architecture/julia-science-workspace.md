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

## First Modeling Target

The first Julia work should ask what mathematical object is being
modeled. For the current architecture, the strongest starting point
is dialogue as a dynamical system rather than dialogue as only a
sequence of discrete turns.

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
only after the state variables and hypotheses are named.

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

The recommended learning order mirrors the architecture:

1. `ModelingToolkit.jl` for symbolic model construction.
2. `DifferentialEquations.jl` for solving ODE systems.
3. `DynamicalSystems.jl` for attractors, sensitivity, and
   stability analysis.
4. `Optimization.jl` for fitting model parameters.
5. `Makie.jl` for trajectories, phase portraits, and bifurcation
   diagrams.

The purpose is not to read package manuals end to end. The purpose
is to build small, inspectable models around named hypotheses.

## First Experiment

Start with one state vector:

```text
x = [
  coherence,
  novelty,
  continuation_pressure,
  semantic_energy
]
```

Posit a simple first-order nonlinear system, simulate trajectories,
and compare them qualitatively against one long soak run. The first
question is not whether the equations are correct. The first question
is whether any continuous dynamical model can reproduce the observed
shape of the behavior.

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
