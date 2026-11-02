# Metric Contracts — The Four Behavioral Axes

> **Status:** Frozen as of 2026-07-21. Changes require an
> ADR-style proposal. New metrics are added here *only* if
> the existing four cannot falsify a hypothesis.

## Why contracts?

The four behavioral metrics (Inertia, RRB, Rhetorical
Motifs, LoA) are the *measurement layer* of the closed
empirical loop. The loop has three orthogonal concerns:

  - **Science** (what we learn) — Experiment, ResearchHypothesis
  - **Engineering** (how we execute) — Runtime, Telemetry, Metrics
  - **Computation** (what runs) — Swift, Rust, Scientific Services

The metric layer lives in the **Engineering** concern.
Hypotheses (Science concern) refer to metrics by *id*.
Rust kernels (Computation concern) can be substituted for
Swift kernels without breaking the metrics, because the
metrics evaluate the *observable behavior* of the
runtime, not the implementation.

**The contract discipline is what makes this possible.**
Each metric has a stable spec: inputs, outputs, known
failure modes, validation. Hypotheses can target a
metric's output without depending on the metric's
implementation. The analyzer code can be rewritten,
optimized, or re-implemented in Rust without invalidating
hypotheses written against the contract.

**The "frozen" status is intentional.** A metric that
changes its definition mid-experiment invalidates all
prior measurements. The four behavioral axes are stable
specs. Any change to a metric's *implementation* (e.g.,
adding a synonym to the motif vocabulary, refining the
LoA term lists) is allowed but must be:

  1. Documented in a commit that references this file
  2. Tested against the validation fixtures
  3. Backwards-compatible (prior measurements still
     compute meaningfully, even if numbers shift)

A change to a metric's *contract* (id, purpose, inputs,
outputs) requires an ADR-style proposal. The metric
becomes a new metric (new id) and the prior metric is
deprecated.

---

## The four contracts

### 1. Inertia (`inertia`)

```yaml
metric:
  id: inertia

purpose: |
  Measure resistance to change in the dialogue across
  three independent dimensions. A healthy dialectic has
  low inertia (it explores freely); a stuck dialectic has
  high inertia on one or more dimensions.

inputs:
  - per-turn spoken text
  - per-turn heard text
  - per-turn outcome (coherence / displacement / synthesis / silent)
  - per-turn next-outcome (the outcome of the *next* turn, used for policy)

outputs:
  semantic_inertia:
    description: |
      Topic resistance. Proxied by 1 - Jaccard similarity
      of consecutive heard lines. High = the user keeps
      saying the same thing. Low = topics shift freely.
    range: [0, 1]
    acceptable_band: [0.00, 0.30]
  linguistic_inertia:
    description: |
      Stereotyped openings. 1 - opening_diversity.
      High = many turns start the same way.
    range: [0, 1]
    acceptable_band: [0.00, 0.40]
  policy_inertia:
    description: |
      Transition determinism. 1 - normalized transition
      entropy of the (outcome, next-outcome) matrix.
      High = the system is in a fixed transition cycle.
    range: [0, 1]
    acceptable_band: [0.00, 0.50]
  exploration_pressure:
    description: |
      1 - policy_inertia. The counterweight. Low pressure
      means the system is in a deterministic attractor.
    range: [0, 1]
    acceptable_band: [0.50, 1.00]
  heard_length_variance:
    description: |
      Variance of the per-turn heard line length.
      High variance = the user is contributing diverse
      input lengths. Low variance = the heard lines
      have settled into a fixed length.
    range: [0, ∞)
  heard_length_autocorrelation_lag1:
    description: |
      Lag-1 autocorrelation of the heard-line length
      series. The critical-slowing-down signature:
      near a stable attractor, autocorrelation rises
      toward 1.0; away from an attractor, it stays
      near 0.
    range: [-1, 1]

known_failure_modes:
  - heard-line jaccard is a *proxy* for semantic inertia;
    genuine semantic inertia requires embeddings (cross-cell
    or cross-model comparisons are not yet possible without
    per-turn embeddings in the JSONL)
  - 30-turn corpora are too short to detect critical
    slowing down; minimum corpus is 100 turns
  - hearing overlap ≠ true semantic equivalence; "yes" and
    "yes please" have very different jaccard but similar
    semantics

validation:
  golden_fixtures:
    - fixtures/inertia/soak-001-baseline.json
    - fixtures/inertia/soak-002-F_qwen05b.json
    - fixtures/inertia/live-283t-baseline.json
  invariants:
    - semantic_inertia + (1 - semantic_inertia) ≈ 1
    - linguistic_inertia + opening_diversity ≈ 1
    - policy_inertia + exploration_pressure ≈ 1
  known_results:
    - soak-001: semantic 0.05, linguistic 0.36, policy 0.28
    - live-283t: semantic 0.05, linguistic 0.36, policy 0.27
```

### 2. Relational Representation Bias (`rrb`)

```yaml
metric:
  id: rrb

purpose: |
  Measure whether the model preferentially reformulates
  interactions in relational terms. The headline finding
  is that this is a *behavioral bias*, not a vocabulary
  preference: the model amplifies relational vocabulary
  beyond what the user provides, in a way that scales
  with interaction length.

inputs:
  - per-turn spoken text
  - per-turn heard text

outputs:
  p_relational_spoken:
    description: |
      Proportion of relational terms (from RELATIONAL_TERMS
      set) in spoken text, per turn, averaged across the
      run.
    range: [0, 1]
  p_relational_heard:
    description: |
      Proportion of relational terms in heard text,
      averaged across the run. This is the per-conversation
      baseline.
    range: [0, 1]
  rrb:
    description: |
      The ratio: p_relational_spoken / p_relational_heard.
      1.0 = no bias. > 1.0 = amplification. < 1.0 = suppression.
    range: [0, ∞)
  rrb_class:
    description: |
      Categorical: amplification (>1.10), neutral (0.90-1.10),
      suppression (<0.90).
  rrb_deviation:
    description: |
      |rrb - 1.0|. A Pareto objective: minimize this.
    range: [0, ∞)

known_failure_modes:
  - the RELATIONAL_TERMS vocabulary is a *hypothesis input*;
    the metric itself is the ratio, which is comparable
    across vocabulary choices
  - amplification can be either emergent (model bias) or
    scaffold-driven (prompt leakage); the architectural
    review's red-team test distinguishes the two
  - 30-turn corpora may not surface the bias; the live-283t
    run shows RRB 1.22 while matrix Qwen 0.5B cells show
    RRB 0.47-0.62. Time scale matters.
  - this metric measures *amplification*, not *bias toward
    relational reasoning*. A model could amplify relational
    vocabulary while reasoning non-relationally.

validation:
  golden_fixtures:
    - fixtures/rrb/soak-001-baseline.json
    - fixtures/rrb/live-283t-baseline.json
  invariants:
    - p_relational_spoken ∈ [0, 1]
    - p_relational_heard ∈ [0, 1]
    - rrb > 0 always
  known_results:
    - live-283t: p_spoken 0.0166, p_heard 0.0138, rrb 1.22
    - matrix F_qwen05b (30 turns): p_spoken 0.0120,
      p_heard 0.0220, rrb 0.55
```

### 3. Rhetorical Motifs (`rhetorical_motifs`)

```yaml
metric:
  id: rhetorical_motifs

purpose: |
  Measure the *discourse structure* of the dialogue, not
  just the vocabulary. The metric decomposes discourse
  into five motif classes and reports a teleological vs
  epistemic orientation. The architectural insight:
  the Witness layer is about observation and grounding,
  not about steering the user toward a predetermined
  narrative of growth. An epistemic orientation is more
  consistent with NeuralCompose's design philosophy.

inputs:
  - per-turn spoken text
  - per-turn outcome (coherence / displacement / synthesis / silent)

outputs:
  motif_counts:
    description: |
      Per-motif class raw counts (adversity, inwardness,
      transcendence, observation, investigation).
  motif_rates_per_1000:
    description: |
      Per-motif rate per 1000 words of spoken text.
  teleological_rate:
    description: |
      (transcendence + inwardness) / total_words.
  epistemic_rate:
    description: |
      (observation + investigation) / total_words.
  teleological_ratio:
    description: |
      teleological_rate / epistemic_rate.
      > 1.10 = teleological
      < 0.90 = epistemic
      0.90-1.10 = balanced
    range: [0, ∞)
  orientation:
    description: |
      Categorical: teleological, balanced, epistemic.
  per_outcome_rates_per_1000:
    description: |
      Per-motif rate per outcome, allowing decomposition
      of synthesis vs coherence vs displacement.

known_failure_modes:
  - the five motif term sets are *hypothesis inputs*;
    different vocabulary choices change the numbers
    but not the metric's structure
  - small corpora (< 30 turns) produce noisy per-outcome
    rates
  - synthesis outcomes are *intrinsically* more
    teleological (the moment of resolution reaches for
    transcendent language); high teleological ratio on
    synthesis alone is not a failure
  - epistemic vs teleological is not the only axis of
    discourse structure; a future trajectory metric
    (e.g., concrete_recurrence) would capture a
    different aspect

validation:
  golden_fixtures:
    - fixtures/motifs/soak-001-baseline.json
    - fixtures/motifs/live-283t-baseline.json
  invariants:
    - sum of motif_rates_per_1000 × 1 ≠ 1 (motifs are
      sparse; total ≠ 1)
    - teleological_ratio > 0 always
  known_results:
    - live-283t overall: tele_ratio 0.36 (epistemic)
    - synthesis outcome: tele_ratio 1.16 (slightly tele)
    - R_qwen15b matrix: tele_ratio 1.36 (teleological)
    - R_qwen05b matrix: tele_ratio 0.12 (epistemic)
```

### 4. Level of Abstraction (`level_of_abstraction`)

```yaml
metric:
  id: level_of_abstraction

purpose: |
  Measure the abstraction level of the dialogue across
  five levels (concrete, interactional, relational,
  societal, existential), and detect *upward abstraction
  drift* over time. The headline finding: drift is
  bimodal (concrete + relational → interactional +
  existential), not ladder-like, and is *model-dependent*
  (Qwen 0.5B and 1.5B focused show upward drift; Qwen
  3B focused shows downward drift).

inputs:
  - per-turn spoken text
  - per-turn outcome (coherence / displacement / synthesis / silent)

outputs:
  distribution:
    description: |
      Per-level proportion of LoA-classifiable words
      in spoken text, averaged across the run.
      The 5-vector: [concrete, interactional, relational,
      societal, existential].
  per_outcome:
    description: |
      Per-level distribution per outcome, allowing
      decomposition of synthesis vs coherence vs
      displacement.
  first_half:
    description: |
      Per-level distribution on the first half of the run.
  second_half:
    description: |
      Per-level distribution on the second half.
  drift:
    description: |
      second_half - first_half, per level. Shows which
      levels are growing or shrinking.
  abstraction_shift:
    description: |
      Weighted change toward higher levels:
        Σ (i/4) * drift[i] for i in 0..4
      Positive = upward drift (H₄ supported).
      Negative = downward (H₄ refuted).
    range: (-∞, ∞)
  h4_verdict:
    description: |
      Categorical: upward_drift (shift > +0.05),
      no_drift, downward_shift (shift < -0.05).

known_failure_modes:
  - the LoA term sets are *hypothesis inputs*; the
    metric's structure (5-vector, weighted shift) is
    stable but the vocabulary choices change the numbers
  - 30-turn corpora are too short to detect drift; the
    metric requires 100+ turns for stable signal
  - "concrete_recurrence" is a trajectory-shape metric
    (does the dialogue return to concrete after
    abstracting?) that LoA cannot capture. It is a
    *future* metric, not part of the current contract.
  - Qwen 3B focused shows *downward* drift; the
    architecture review's H₄ hypothesis ("upward drift
    is universal") is partially refuted. The metric
    correctly reports the direction regardless of the
    hypothesis.

validation:
  golden_fixtures:
    - fixtures/loa/soak-001-baseline.json
    - fixtures/loa/live-283t-baseline.json
  invariants:
    - sum(distribution) ≤ 1 (LoA-classifiable words
      are a subset of total words)
    - sum(drift) = 0 approximately (the 5-vector is
      conserved; only the redistribution changes)
  known_results:
    - live-283t overall: distribution C=0.27 I=0.23
      R=0.30 S=0.06 E=0.15; shift +0.044 (no drift,
      just below threshold)
    - F_qwen05b matrix (30 turns): shift +0.219
      (H₄ supported)
    - F_qwen3b matrix (30 turns): shift -0.100
      (H₄ refuted)
    - live-283t per-outcome: synthesis has higher
      existential (0.20) than coherence (0.11) or
      displacement (0.16)
```

---

## Cross-axis properties

The four metrics are *orthogonal*: a hypothesis that
achieves good performance on one axis may not achieve
good performance on the others. The Pareto analysis
in `Scripts/pareto_frontier.py` evaluates all four
simultaneously.

| axis    | orthogonal to | because                          |
|---------|---------------|----------------------------------|
| Inertia | RRB           | inertia measures resistance; RRB measures amplification |
| Inertia | Motifs        | inertia measures stuckness; motifs measure orientation |
| Inertia | LoA           | inertia measures stability; LoA measures abstraction level |
| RRB     | Motifs        | RRB measures relational amplification; motifs measure teleology |
| RRB     | LoA           | RRB is one of the LoA classes; RRB is a *ratio*, LoA is a *distribution* |
| Motifs  | LoA           | motifs are *discourse structure*; LoA is *abstraction level*. The overlap is the "transcendence" motif, which counts toward both, but the metrics' structures are independent. |

A hypothesis is admitted to the Pareto frontier if it
*dominates* the current best on at least one axis without
losing on any other axis. This is the falsifiability
discipline the architecture review enforces.

## Future metrics (out of contract)

These are *named* future metrics, not part of the current
contract:

- `concrete_recurrence` — does the dialogue return to
  concrete vocabulary after abstraction drift? A
  trajectory-shape metric, not a distribution metric.
  Required to distinguish "healthy" (drift + return) from
  "unhealthy" (drift + escalate) trajectories.
- `phase_portrait` — full trajectory analysis, not a
  scalar or 5-vector. Replaces the question "what was
  the average abstraction?" with "what phase portrait
  did this dialogue follow?"
- `transition_topology` — graph-theoretic analysis of
  the (outcome, next-outcome) state machine. Quantifies
  whether the system is in a small attractor cycle or
  a larger exploration basin.

These will be added *only if* the four existing axes
cannot falsify a specific hypothesis. The metric-
accumulation phase is over.

## Why this is part of the Engineering concern

The metric contracts are the boundary between the
**Science** concern (hypotheses ask questions about
behavior) and the **Computation** concern (Rust kernels
implement the algorithms). By freezing the contracts,
we let both layers evolve independently:

- A hypothesis can be written against a contract (e.g.,
  "rrb < 1.10") without knowing whether the metric is
  computed in Python, Swift, or Rust.
- A Rust kernel can be substituted for a Swift kernel
  without changing the metric's output, as long as the
  contract's `inputs` and `outputs` are preserved.

The contracts are the *interface* between Science and
Computation. Engineering (the metric implementation) is
the only layer that needs to track both.

Refs: `docs/rvs/soak-003-inertia-pareto.md`,
`docs/rvs/soak-004-symbolic-drift.md`,
`docs/rvs/soak-005-rhetorical-motifs.md`,
`docs/rvs/soak-006-loa.md`. The three orthogonal
concerns (Science / Engineering / Computation) come
from the architecture review on 2026-07-21.
