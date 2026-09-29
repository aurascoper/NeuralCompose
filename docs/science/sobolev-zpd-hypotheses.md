# Sobolev And ZPD Hypotheses

> Status: Draft (2026-07-22). This note places Sobolev learning
> and Zone of Proximal Development ideas inside the three-concern
> architecture. They are hypothesis generators, not runtime modes.

## Placement

Sobolev learning and ZPD belong in different concerns:

```text
Science
  Sobolev hypotheses
  ZPD hypotheses

Engineering
  derivative telemetry
  intervention-distance telemetry
  feature contracts

Computation
  Julia reference models
  Rust deterministic operators
  Swift interaction policy
```

Neither idea should be baked into prompts or UI as an identity. Each
must become a falsifiable claim against measured telemetry.

## Sobolev Learning

Sobolev methods do not only learn a function:

```text
f(x)
```

They also care about derivatives:

```text
df/dx
```

For NeuralCompose, that means the scientific object is not only a
dialogue state point. It is the trajectory:

```text
state
  -> velocity
  -> acceleration
  -> stability
```

A Sobolev-flavored hypothesis might be:

```text
Adding derivative-matching regularization to dialogue trajectory
fitting reduces held-out one-step prediction error by at least X%
without increasing instability.
```

Julia is the natural place to fit and falsify that model. Rust only
appears later if a validated derivative operator deserves a
deterministic implementation.

## ZPD

ZPD is not primarily about fitting the field. It is about choosing an
intervention:

```text
What is the smallest useful move that advances the dialogue?
```

That belongs near interaction policy, between a world/dialogue model
and generation:

```text
world model
  -> intervention policy
  -> generation
```

A ZPD-inspired policy can be parameterized by:

```text
challenge_level
hint_strength
ambiguity_tolerance
silence_threshold
continuation_pressure
```

A falsifiable hypothesis might be:

```text
A proximal intervention policy increases constructive continuation
while reducing abstraction drift compared with the baseline policy.
```

Swift may eventually host the interaction policy because Swift owns
orchestration and user-facing behavior. That should happen only after
Science defines the measurable policy and Engineering can record the
intervention-distance telemetry.

## Shared Dynamical View

The common frame is dialogue as motion on a measured state manifold:

```text
telemetry
  -> state reconstruction
  -> local dynamics
  -> intervention policy
  -> runtime behavior
```

Sobolev learning asks:

```text
Can we estimate a smooth local vector field?
```

ZPD asks:

```text
Can we choose a short, productive control input along that field?
```

Those are estimation and control questions over the same system. That
is useful only if kept empirical: models must predict held-out
telemetry, policies must improve named metrics, and validated
operators must cross the Rust/Swift boundary deliberately.
