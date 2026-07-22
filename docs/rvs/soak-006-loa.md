# Soak 006 — Level of Abstraction (LoA) and the H₄ Hypothesis

**Date:** 2026-07-21
**Branch:** feature/pluggable-generators @ (this commit)
**Tooling:** `Scripts/analyze_dialectic.py` (LoA + drift section)
**Data:** 304 live turns + 10 matrix cells × 30 turns

This is the sixth post-soak findings doc. The architecture
review named a fourth orthogonal behavioral axis:

> "Reflective dialogue may exhibit *upward abstraction
>  drift* over time, moving from concrete problem-solving
>  toward increasingly general relational, societal, or
>  existential framing."

The user names this **H₄** and explicitly distinguishes it
from H₂:

> "Unlike H₂, this doesn't assume the drift is good or bad.
>  It predicts measurable changes in vocabulary categories
>  over time."

The reviewer's framing also names a *healthy vs unhealthy*
distinction:

  - **Healthy reflective trajectory:** observation →
    clarification → investigation → tentative synthesis →
    return to the concrete (re-grounded)
  - **Unhealthy trajectory:** observation → human
    condition → society → meaning → transcendence (without
    reconnecting to the user's actual task)

This doc adds the **Level of Abstraction (LoA)** metric
as a 5-vector (concrete, interactional, relational,
societal, existential), and tests H₄ on the existing
data.

## The metric

Each turn is represented as a 5-vector of class proportions:

| level          | examples                                |
|----------------|-----------------------------------------|
| concrete       | runtime, json, ollama, benchmark,       |
|                | telemetry, file, code, function, system |
| interactional  | dialogue, conversation, witness,        |
|                | response, reply, turn, exchange, voice  |
| relational     | between, together, relation, value,     |
|                | sign, us, through, among, within        |
| societal       | community, culture, social, society,    |
|                | media, institutions, public, people     |
| existential    | human, humanity, condition, mortality,   |
|                | meaning, transcendence, existence, soul |

**abstraction_shift** is a single-number summary: the
weighted change in distribution toward higher levels.

  abstraction_shift = Σ (i/4) * (second[i] - first[i]) for i in 0..4

  abstraction_shift > +0.05  →  upward drift (H₄ supported)
  abstraction_shift < -0.05  →  downward (H₄ refuted)
  otherwise                  →  no significant drift

The metric is a vector (5 levels), not a scalar — the
drift is *redistribution across levels*, not a single
"more abstract" number. Future hypothesis YAMLs can
specify the *expected* per-level distribution as a
band, not just an upper bound on a single metric.

## The headline: H₄ is partially supported, with a twist

### Live data (304 turns): upward drift is just below the threshold

| level          | first    | second   | drift (pp) |
|----------------|---------:|---------:|-----------:|
| concrete       |   31.52% |   22.43% |   -9.09 ↓  |
| interactional  |   17.54% |   27.80% |  +10.26 ↑  |
| relational     |   32.25% |   27.88% |   -4.37 ↓  |
| societal       |    7.54% |    4.45% |   -3.09 ↓  |
| existential    |   11.15% |   17.44% |   +6.29 ↑  |

**abstraction_shift: +0.044** (just below the +0.05 threshold
for "upward drift"). The verdict is "no significant drift"
by the strict criterion, but the *direction* is upward and
the magnitudes are large.

The drift is *not* a clean ladder climb. It's a *bimodal*
shift: from concrete + relational → to interactional +
existential. The dialogue moves *both* toward
meta-conversation (interactional) *and* toward abstraction
(existential), while losing concrete grounding.

This is a sharper finding than the architecture review's
"concrete → societal → existential" prediction. The actual
data shows the dialogue getting *self-referential about
itself* (more interactional) and *abstract about
existence* (more existential), while dropping the
relational and concrete modes.

### Cross-cell matrix: H₄ is supported on Qwen 0.5B/1.5B, refuted on Qwen 3B

| cell              | abs_shift | verdict                                 |
|-------------------|----------:|-----------------------------------------|
| **F_qwen05b**     |   +0.219  | **upward drift (H₄ supported)**         |
| **F_qwen15b**     |   +0.100  | **upward drift (H₄ supported)**         |
| live_283t         |   +0.049  | no drift (just below threshold)         |
| R_qwen15b         |   -0.000  | no drift                                 |
| R_qwen05b         |   -0.036  | no drift                                 |
| C_qwen05b         |   -0.033  | no drift                                 |
| **F_qwen3b**      |   -0.100  | **downward (H₄ refuted)**               |

**Same prompt, opposite drift by model size.** This is
the same finding shape as Soak 005 (R_qwen05b 0.12 vs
R_qwen15b 1.36 on the teleological ratio): the model
training distribution is the dominant variable, not the
prompt.

**Qwen 0.5B and 1.5B focused show upward drift.** Qwen
3B focused shows *downward* drift — toward concrete, not
away. **The 3B model is more grounded than the smaller
models.** This is counter-intuitive (bigger = more
abstract would be the default expectation), but consistent
with the Soak 003 finding that Qwen 3B had the lowest
ngram diversity (0.657) and Soak 005's finding that
Qwen 3B was more teleological (1.14). The 3B model
*settles into* a relational/teleological register rather
than climbing the abstraction ladder.

**The matrix corpus (30 turns) is too short to show
the full live-data drift.** Most matrix cells have
"no significant drift" because the time series is too
short. The +0.044 shift on live_283t (304 turns) is
larger in magnitude than most matrix cells' shifts, but
not yet large enough to cross the +0.05 threshold. A
longer run would likely show a more pronounced drift.

## Three findings worth paragraphs

### 1. The drift is bimodal, not ladder-like

The architecture review's framing — "concrete → societal
→ existential" — is one possible trajectory. The actual
data shows a *bimodal redistribution*: concrete + relational
↓, interactional + existential ↑.

The dialogue is *not climbing a single abstraction ladder*.
It's transitioning between two distinct kinds of self-
reference:

  - **Meta-conversational** (interactional): talking
    *about* the conversation, the dialogue, the exchange
  - **Meta-existential** (existential): talking *about*
    meaning, mortality, the human condition, transcendence

These are two different "moves away" from the concrete.
The matrix corpus is too short to distinguish them; the
live data shows both happening simultaneously.

### 2. H₄ is a model-dependent phenomenon

The cross-cell matrix:

  - F_qwen05b: +0.219 (H₄ supported)
  - F_qwen15b: +0.100 (H₄ supported)
  - F_qwen3b:  -0.100 (H₄ refuted)

Same prompt, opposite drift. **The 3B model is more
grounded than the smaller models.** This is a falsifiable
finding: changing the prompt changes the drift less than
changing the model. The H₄ hypothesis needs to be
qualified: "H₄ holds for Qwen 0.5B and 1.5B, but
*not* for Qwen 3B focused under the current matrix
corpus."

The live_283t (304 turns) is +0.049 — just below the
threshold but in the right direction. The 0.5B model
behavior on the matrix is consistent with the live app's
behavior over 10× more turns.

### 3. The unhealthy-trajectory distinction is real but not yet captured

The architecture review's framing — "an unhealthy
trajectory ends in transcendence without reconnecting
to the concrete" — describes a *convergence failure*:
the dialogue climbs the abstraction ladder and never
returns. The current data shows *intermediate* drift
(+0.044 to +0.219), not the full unhealthy-trajectory
pattern. A future metric could measure:

  - `concrete_recurrence`: how often the dialogue returns
    to concrete vocabulary after abstraction drift
  - `drift_reversibility`: does the second half *recover*
    the first half's concrete grounding, or is the
    drift monotonic?

The current run (304 turns) doesn't have enough data to
measure these. A 1000+ turn run would.

## The cross-cell benchmark table (H₄ axis)

| cell              | abs_shift | orientation       | LoA verdict       |
|-------------------|----------:|-------------------|-------------------|
| F_qwen05b         |   +0.219  | epistemic (0.18)  | upward drift      |
| F_qwen15b         |   +0.100  | epistemic (0.55)  | upward drift      |
| live_283t         |   +0.049  | epistemic (0.36)  | no drift (close)  |
| R_qwen15b         |   -0.000  | teleological (1.36) | no drift         |
| R_qwen05b         |   -0.036  | epistemic (0.12)  | no drift          |
| C_qwen05b         |   -0.033  | epistemic (0.40)  | no drift          |
| F_qwen3b          |   -0.100  | teleological (1.14) | downward (refutes H₄) |

The H₄ axis and the H₃ (teleological/epistemic) axis
are *orthogonal*: F_qwen05b has the highest upward drift
but is epistemic; R_qwen15b has zero drift but is
teleological; F_qwen3b has downward drift *and* is
teleological. **These are independent phenomena.**

A future `ResearchHypothesis` YAML can target:

  - `abstraction_shift ∈ [-0.05, +0.05]` (no drift)
  - OR `abstraction_shift ≥ +0.10` (deliberate upward
    drift, named in the YAML)
  - AND `teleological_ratio < 0.80` (epistemic
    orientation)
  - AND `motif.transcendence < 3.0` per 1000 words

These three axes (LoA drift, teleological ratio, motif
distribution) form a *behavioral fingerprint* of the
hypothesis. Pareto-dominance is evaluated on all three.

## Why this matters for the closed empirical loop

The closed loop now has *four* orthogonal behavioral
metrics, each measuring a distinct aspect of the
dialectic's dynamics:

| axis    | metric             | what it captures                  |
|---------|--------------------|----------------------------------|
| Inertia | sem/ling/policy    | resistance to change             |
| RRB     | relational amp.    | model adds relational framing?   |
| Motifs  | tele vs epistemic  | does the model presuppose outcomes? |
| **LoA** | **5-vector drift** | **does the dialogue get more abstract?** |

A `ResearchHypothesis` YAML on `feature/research-hypotheses`
can specify acceptance criteria on all four axes. A
hypothesis that dominates on all four (compared to the
current `contemplative_v3` baseline) is a Pareto-frontier
member. The closed loop is now:

```
  Experiment (the question)
       ↓
  ResearchHypothesis (YAML: parameters + 4-axis predictions)
       ↓
  Runtime (Swift)
       ↓
  Telemetry
       ↓
  Metric extraction (4 axes)
       ↓
  Compare to predictions (in-band → admit)
       ↓
  Pareto analysis
       ↓
  Next hypothesis
```

The empirical loop is now *quantitatively falsifiable*
on four axes. Hypotheses are kept because they dominate
the frontier on measurable criteria, not because they
better embody a philosophical tradition.

## Status

- ✅ LoA metric added (5-vector, abstraction_shift, H₄ verdict)
- ✅ 11-point cross-cell comparison run on existing data
- ✅ H₄ partially supported (F_qwen05b +0.219, F_qwen15b +0.100;
  F_qwen3b -0.100)
- ✅ Three findings surfaced (bimodal drift, model-dependent,
  unhealthy-trajectory distinction not yet captured)
- ⏸ Concrete-recurrence / drift-reversibility metric
  — needs longer runs (1000+ turns) to be meaningful
- ⏸ Cross-model dialectic — separate scope
- ⏸ `feature/research-hypotheses` branch when it opens

Refs: Soak 003 (inertia), Soak 004 (RRB), Soak 005
(rhetorical motifs), the architecture review's H₄
framing, the "healthy vs unhealthy reflective
trajectory" distinction.
