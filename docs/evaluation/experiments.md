# Experiment Schema

> **Status:** Draft (2026-07-21). The schema is proposed
> here for the first time. It will be revised when the
> `feature/research-hypotheses` branch opens. The schema
> is meant to *separate questions from proposed answers*,
> not to lock either in prematurely.

## Why experiments?

The architecture review named a structural change:

> "Hypotheses propose answers. Experiments ask questions.
>  Those are different concepts. The separation becomes
>  valuable once you have dozens of hypotheses."

Without the experiment layer, a hypothesis is a
parameterization without a *reason*. The reason lives in
the question the experiment asks. A hypothesis that is
admitted to the Pareto frontier is one that *answers the
experiment's question well*, not one that embodies a
particular philosophy.

Concretely: the experiment is the *scientific object*.
The hypothesis is the *candidate answer*. The runtime
is the *execution*. The metrics evaluate whether the
candidate answer is consistent with the evidence.

## The schema

```yaml
experiment:
  id: EP-001                  # unique identifier (EP-NNN)

  title: >
    Reduce synthesis pressure to lower abstraction drift.

  question: |
    Does reducing the synthesis pressure parameter lower
    the abstraction drift in long-running reflective
    dialogues? The hypothesis is that synthesis outcomes
    are intrinsically more teleological (per the
    rhetorical_motifs metric), and that fewer synthesis
    events will reduce the drift toward existential
    vocabulary.

  background: |
    Per the Soak 005 findings, synthesis outcomes have
    teleological_ratio 1.16 (vs 0.34 for coherence and
    0.43 for displacement). Per the Soak 006 findings,
    the live app shows abstraction_shift +0.044 with
    existential vocabulary increasing by 6.29pp from
    first to second half. The conjecture: synthesis is
    the source of the existential drift.

  hypotheses:
    - id: reflective_v2
      summary: Reduce synthesis_pressure by 50%
      source: docs/hypotheses/reflective_v2.yaml
    - id: contemplative_v4
      summary: Reduce synthesis_pressure to 0
      source: docs/hypotheses/contemplative_v4.yaml
    - id: reflective_baseline
      summary: Default synthesis_pressure (= contemplative_v3)
      source: docs/hypotheses/contemplative_v3.yaml

  metrics:
    - inertia                # id from docs/evaluation/metrics.md
    - rrb
    - rhetorical_motifs
    - level_of_abstraction

  predictions:
    # Predicted per-hypothesis behavior. Hypotheses are
    # admitted to the Pareto frontier if their observed
    # behavior matches the prediction.
    reflective_v2:
      abstraction_shift: [+0.00, +0.04]   # smaller upward drift
      teleological_ratio: [0.00, 0.80]   # still epistemic
    contemplative_v4:
      abstraction_shift: [-0.05, +0.05]  # no drift (force ground)
      teleological_ratio: [0.00, 0.70]   # most epistemic
    reflective_baseline:
      abstraction_shift: [+0.04, +0.10]  # current observed drift
      teleological_ratio: [0.30, 0.50]   # current observed

  decision_rule: pareto

  runtime_config:
    pole_a: qwen2.5:0.5b
    pole_b: qwen2.5:0.5b
    profile: reflective
    corpus: fixtures/corpora/soak-002-30turns.jsonl

  status: proposed
  proposed_at: 2026-07-21
  proposed_by: architecture-review

  outcome: null               # filled in after the experiment runs
```

## Field reference

| field | type | purpose |
|---|---|---|
| `id` | string | Unique identifier (EP-NNN) |
| `title` | string | Short human-readable title |
| `question` | string | The scientific question being asked |
| `background` | string | Why this question matters; prior findings that motivate it |
| `hypotheses` | list | The candidate answers, with `id`, `summary`, `source` |
| `metrics` | list | The metric ids from `docs/evaluation/metrics.md` used for evaluation |
| `predictions` | dict | Per-hypothesis predicted behavior (in-band) |
| `decision_rule` | enum | How to determine the experiment's outcome (currently only `pareto`) |
| `runtime_config` | dict | The runtime configuration for the experiment |
| `status` | enum | `proposed`, `running`, `complete`, `inconclusive`, `rejected` |
| `outcome` | dict | Filled in after the experiment runs (per-hypothesis observed values) |

## What an experiment is *not*

- It is *not* a hypothesis. Hypotheses are parameterizations.
  Experiments are questions. A hypothesis without an
  experiment is unanchored; an experiment without
  hypotheses has nothing to test.

- It is *not* a benchmark. Benchmarks measure performance
  against a fixed reference. Experiments evaluate whether
  a hypothesis is consistent with the evidence.

- It is *not* a commit or a code change. The experiment
  is a YAML that lives in `docs/experiments/`. The code
  that runs it is the runtime + analyzer, not the
  experiment.

## The closed loop

An experiment completes when its hypotheses have been
run, evaluated, and admitted (or rejected) on the Pareto
frontier. The loop is:

```
  Experiment (the question)
       │
       ▼
  Hypotheses (the proposed answers)
       │
       ▼
  Runtime (the execution)
       │
       ▼
  Telemetry (the facts)
       │
       ▼
  Metric extraction (the four axes)
       │
       ▼
  Compare to predictions
       │   in-band → admitted to frontier
       │   out-of-band → next hypothesis
       ▼
  Pareto analysis
       │
       ▼
  Next hypothesis
```

The experiment schema is the *entry point* for this
loop. Without it, hypotheses accumulate without anyone
asking what they're for. With it, the loop is closed:
every hypothesis is a candidate answer to a named
question.

## When the schema lands

The schema is proposed here but not yet implemented in
code. The work to land it:

1. Open `feature/research-hypotheses` branch
2. Create `Sources/BCICore/Configuration/Experiment.swift`
   (the schema as a Swift struct)
3. Create `Sources/BCICore/Configuration/ExperimentLoader.swift`
   (YAML loader, parallel to the existing prompts loader)
4. Create `docs/experiments/` directory with 2-3 starter
   experiments
5. Wire `NEURALCOMPOSE_EXPERIMENT` env var in
   `LiveRuntimeFactory` (parallel to the runtime env var)
6. Add `Scripts/experiment_runner.py` to run an experiment
   and emit the comparison-vs-prediction report

This is **Priority 2** in the architecture review's
ordering (after the runtime merge, before Rust Phase 0).

## Out of scope

The schema is *not* a workflow management system. It does
not track who is responsible for an experiment, deadlines,
or approval chains. Those concerns are for issue trackers
and project management tools, not for the experiment
specification.

The schema is *not* a meta-language. It does not let
experiments spawn other experiments. Recursive
experimental design is a future research direction, not
a current need.

Refs: The architecture review on 2026-07-21; the metric
contracts in `docs/evaluation/metrics.md`; the
four-behavioral-axis framework from Soaks 003-006.
