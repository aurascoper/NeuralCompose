# Symbolic Systems As Hypothesis Sources

> Status: Draft (2026-07-22). This note places historical symbolic
> systems such as geomancy inside NeuralCompose's scientific workflow.
> They are objects of study and sources of hypotheses, not runtime
> mechanisms.

## Placement

Geomancy, I Ching-style transformations, semiotic systems, and
philosophical traditions belong in Science only as literature and
hypothesis sources:

```text
Science
  literature review
  historical symbolic systems
  hypothesis generation

Engineering
  runtime
  telemetry
  metrics

Computation
  Swift
  Rust
  Julia
```

They should not become application modes, privileged decision rules,
or unfalsifiable policies.

## Non-Goals

Do not add:

- `GeomancyMode`
- divination policies
- prompt identities that claim symbolic authority
- runtime decisions based on symbolic figures

Those would bypass the empirical framework. A tradition earns
attention only when it can be translated into measurable parameters,
predictions, and metrics.

## Testable Translation

The scientifically interesting abstraction is not divination. It is
finite symbolic state dynamics. A research question could be:

```text
Can dialogue dynamics be represented as transitions among a small
number of recurrent symbolic states?
```

An empirical workflow would look like:

```text
telemetry
  -> continuous state
  -> clustering
  -> discrete symbolic states
  -> transition graph
  -> predictive comparison
```

Possible hypotheses:

```text
A learned finite-state abstraction predicts next-turn outcomes better
than continuous state alone.

A transition graph over coarse symbolic states improves interpretability
without reducing held-out prediction accuracy.
```

Julia is the right place to test these ideas through clustering,
hidden-state models, Markov analysis, symbolic dynamics, and
information-theoretic comparisons. Rust only appears if a validated
state-transition algorithm deserves deterministic implementation.

## Priority

This is not a near-term implementation priority. The current roadmap
has higher leverage:

1. Runtime unification.
2. ResearchHypothesis framework.
3. Rust Phase 0 deterministic measurement.
4. Julia state reconstruction and dynamical systems.
5. Sobolev learning, control, and ZPD-inspired intervention policies.

Symbolic systems become relevant only after the empirical framework is
mature enough to reject them.
