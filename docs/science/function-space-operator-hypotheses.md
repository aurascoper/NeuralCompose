# Function-Space And Operator Hypotheses

> Status: D0 foundations registered 2026-07-24. These are Science-layer
> hypotheses and mathematical fixtures, not runtime modes or EEG methods.

## Placement

Function-space work asks how observations, fitted functions, derivatives, and
representations relate under explicit measures and operators:

```text
Science
  empirical-measure questions
  Sobolev/Tikhonov hypotheses
  operator-stability hypotheses

Computation
  deterministic Julia reference fixtures

Engineering
  unchanged unless a later empirical experiment registers a measurement
```

`EXP-FUNC-SYN-000` is the D0 synthetic rehearsal. It establishes
implementation behavior only:

- FS0 demonstrates finite-sample pseudometric equivalence.
- FS1 separates parameter AD from numerical signal differentiation.
- FS2 solves a finite-basis Sobolev/Tikhonov problem.
- FS3 illustrates Egorov's theorem.
- FS4 measures operator stability.
- FS5 integrates a synthetic continuous-plus-atomic measure.

The governing [decision
memo](../research/function-space-foundations-decision-memo-v0.md) and
[machine-readable contract](../../configs/function-space-foundations-v0.json)
retain `decision: insufficient_evidence` and
`promotion_status: not_eligible`.

## Later Hypotheses

A later empirical hypothesis may ask whether a preregistered regularized
derivative estimate improves held-out prediction or robustness relative to
raw and filtered finite differences. It must define:

- the measured target;
- the data and split unit;
- train-only regularization selection;
- baselines and failure criteria;
- whether any preprocessing behavior would change.

No such physical-data study is authorized by the D0 package.

## Representation Boundary

The representation term in the operator objective is explanatory. Variance,
covariance, singular-spectrum, effective-rank, and collapse controls remain in
the existing JEPA contracts. This document does not create another
representation trainer.
