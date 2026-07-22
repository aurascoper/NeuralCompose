# Three Orthogonal Concerns

> **Status:** Draft (2026-07-21). The architecture review
> named a structural separation that supersedes the
> five-stage execution pipeline. This document captures
> the new frame as the canonical structural reference.

## The shift

The project has matured from "an AI application" to
"an experimental platform." The previous structural
model was a five-stage execution pipeline:

```
  Experiment → ResearchHypothesis → Runtime → Telemetry → Metrics
```

That's a useful pipeline but it conflates two distinct
kinds of concern. The architecture review's reframing
splits the pipeline into **three orthogonal concerns**:

```
  SCIENCE
   - What are we trying to learn?
   - Experiment
   - ResearchHypothesis

  ENGINEERING
   - How is it executed?
   - Runtime
   - Telemetry
   - Metrics

  COMPUTATION
   - What executes the algorithms?
   - Swift Runtime
   - Rust Kernels
   - Scientific Services (Julia / Python / R / Stan)
```

The five-stage pipeline is preserved *inside* the
three concerns:

```
  SCIENCE:        Experiment → ResearchHypothesis
  ENGINEERING:   Runtime → Telemetry → Metrics
  COMPUTATION:   Swift Runtime, Rust Kernels, ...
```

Each concern evolves at a *different rate*:

- **Science** changes frequently — new questions, new
  hypotheses, new experimental designs
- **Engineering** changes occasionally — runtime refactors,
  telemetry schema changes, metric contract updates
- **Computation** changes slowly — Swift, Rust, Julia
  boundaries; the choice of language and the boundary
  surface

The separation is valuable because it lets you replace
one layer without disturbing the others. Concretely:

- A new `ResearchHypothesis` (Science) is implemented
  without touching the runtime (Engineering) or the
  compute kernels (Computation).
- The runtime can be refactored (Engineering) without
  changing the hypothesis or the computation layer.
- Rust can be substituted for Swift (Computation) without
  changing what hypotheses ask or what metrics measure,
  as long as the runtime contract is preserved.

## The closed loop, recast

The closed empirical loop in the three-concern frame:

```
  SCIENCE
    Experiment (the question)
       │
       ▼
    ResearchHypothesis (the proposed answer)
       │
       │   ────────────────────────────
       ▼                                │
  ENGINEERING                       COMPUTATION
    Runtime                            Swift kernels
       │                              Rust kernels
       │   ──────────────────────     Scientific services
       ▼                                │
    Telemetry                            │
       │   ──────────────────────       │
       ▼                                │
    Metrics                              │
       │   ──────────────────────────── │
       ▼
    Compare to predictions
       │
       ▼
    Pareto analysis
       │
       ▼
    Next hypothesis
       │
       └─── loops back to SCIENCE ─────┘
```

The arrows between concerns are *contracts*, not
implementations. The hypothesis (Science) refers to
metric ids (Engineering) by name. The runtime
(Engineering) calls into compute kernels (Computation)
through a stable interface (e.g., the C ABI for Rust,
the protocol seam for Swift).

The contracts that bridge the concerns are:

- **Science ↔ Engineering:** metric contracts in
  `docs/evaluation/metrics.md`. Hypotheses target metric
  ids; the implementation can change without breaking
  hypotheses.
- **Engineering ↔ Computation:** runtime interfaces
  (the `TextGenerating` protocol seam for Swift; the
  C ABI for Rust; the cross-language contract for
  scientific services). The runtime can call into any
  computation layer that satisfies the interface.

## What this changes

### Before the three-concern frame

Hypotheses were often *philosophies*:
- "Lacan mode" (a profile that embodies a philosophical
  tradition)
- "Wolframian dynamics" (a profile shaped by a particular
  theoretical framework)

The books were *authorities embedded in code*. The
problem: philosophical traditions are not falsifiable.
A profile that "follows Lacan" can be defended
indefinitely because there's no criterion for being
wrong.

### After the three-concern frame

Hypotheses are *parameterizations*:
- "Increasing continuation pressure changes measurable
  dialogue behavior" (a falsifiable claim about a
  parameter and an outcome)
- "Reducing synthesis pressure lowers abstraction drift"
  (a falsifiable claim about a parameter and a metric)

The books are *sources of hypothesis generation*. The
Wolfram framing suggests a parameter (continuation
pressure); the Lacan framing suggests another parameter
(signifier weight). The parameters are the *test* of
whether the framing has predictive value.

This is the shift from "the books tell us how to write
profiles" to "the books tell us what parameters to test."

## The runtime as the single execution path

The architecture review named a structural problem:

```
  Live App
        \
         \
  Harness -------> Telemetry
```

The live app and the harness use *different* runtime
paths. The live app uses `LiveRuntimeFactory`; the
harness uses `dialectic-session`. They share telemetry
but not the runtime itself.

The target is *one* execution path:

```
             RuntimeFactory
                  │
      ┌───────────┴───────────┐
      ▼                       ▼
   Live App               Harness
      │                       │
      └───────────┬───────────┘
                  ▼
              Telemetry
```

Once there is one execution path, every future
experiment is more trustworthy. The live-app
`LiveRuntimeFactory` env-var fix and the cross-model
dialectic harness extension are the prerequisites for
this unification.

**The next merge is more important than the next feature.**
Opening `feature/research-hypotheses` before the runtime
path is unified risks fragmenting the experiments across
two execution paths. The merge candidate is
`feature/pluggable-generators` into `main` after the
runtime unification lands.

## The Rust role, clarified

Rust is *not* arriving to "make NeuralCompose faster."
It's arriving to stabilize **deterministic computational
kernels** beneath a mature experimental framework.

The four-gate evaluation order (Correctness → Numerical
stability → Determinism → Performance) is *the* discipline
that makes this scientific. A kernel that passes gate 1
(correctness) but fails gate 3 (determinism) is *not
ready* for Phase 1, even if it's fast. Performance
alone is not sufficient.

When Rust Phase 0 begins, it will already have:

- Stable telemetry (the four-axis metric contracts)
- Stable benchmarks (the matrix corpus + live data)
- Acceptance criteria (the metric contract bands)
- Repeatable experiments (the schema in
  `docs/evaluation/experiments.md`)
- Reproducible runtime selection (the unified
  RuntimeFactory)

That means every Rust kernel can be evaluated
scientifically instead of anecdotally. The four-gate
order is the evaluation discipline.

## Julia / Python / R as offline scientific services

The scientific services tier (Julia, Python, R, Stan)
is *not* a runtime tier. It's an offline research
service tier that *consumes* runtime artifacts (telemetry,
hypotheses, metric outputs) and produces *insights* that
inform the next Science-layer artifact (a new
hypothesis, a refined metric, a new experiment).

The closed loop has a Science-tier role for these
services: they help generate the *next* question, not
the *current* answer. Julia for stability analysis,
bifurcation diagrams, and manifold learning. R for
statistical inference. Stan for Bayesian uncertainty.
Python for general scripting and analysis glue.

These services are not in the runtime path. They are
in the *research path* that surrounds the runtime.

See `julia-science-workspace.md` for the repository boundary and
promotion path for Julia models.

## Status

- Three orthogonal concerns named and documented
- Closed loop recast in the three-concern frame
- Runtime unification identified as Priority 1
- Metric contracts identified as the Science ↔ Engineering
  bridge (`docs/evaluation/metrics.md`)
- Experiment schema identified as the Science-layer
  entry point (`docs/evaluation/experiments.md`)
- Rust's clarified role: deterministic kernels beneath
  a mature framework, not optimization
- Scientific services clarified: offline, not runtime

## Next steps (per the architecture review)

1. **Runtime unification** — `LiveRuntimeFactory` env-var
   fix + cross-model harness + merge into `main`
2. **Freeze the measurement layer** — the four metric
   contracts in `docs/evaluation/metrics.md`
3. **Open `feature/research-hypotheses`** — the
   `Experiment → ResearchHypothesis` schema
4. **Use the four metrics** to evaluate carefully chosen
   hypotheses
5. **Rust Phase 0** — gated on the four-gate evaluation
   order; only after #1 and #3 are stable

Refs: The architecture review on 2026-07-21; the
metric contracts in `docs/evaluation/metrics.md`; the
experiment schema in `docs/evaluation/experiments.md`.
