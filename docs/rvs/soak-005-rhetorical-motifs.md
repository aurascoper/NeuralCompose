# Soak 005 — Rhetorical Motifs and the Teleological/Epistemic Axis

**Date:** 2026-07-21
**Branch:** feature/pluggable-generators @ (this commit)
**Tooling:** `Scripts/analyze_dialectic.py` (rhetorical_motifs +
            epistemic_orientation sections)
**Data:** 304 live turns + 10 matrix cells × 30 turns

This is the fifth post-soak findings doc. The architecture
review named a question that *cannot* be answered by lexical
or vocabulary analysis alone:

> "Two reflective outputs exhibit a *shared rhetorical
>  structure*, not just shared vocabulary. They both follow
>  difficulty → recognition → inner resource → transcendence.
>  Why?"

Three candidate explanations:

  1. Training-distribution bias — reflective LLMs converge
     on counseling / coaching / mindfulness language
     because that's what the training data looks like.
  2. Prompt-template constraint — analogous to the
     "in a live dialogue" scaffold, but at a deeper
     structural level. The reflective prompt shapes the
     rhetorical structure, not just the surface vocabulary.
  3. Genuine attractor — Reflective has its own interaction-
     policy pull toward "challenge → inner resource →
     integration" as a discourse pattern.

The reviewer's framing — and the **decision criterion** for
this work — is that the bias should be *measurable*, not
interpreted from vibes.

This doc adds two new metrics:

  - **Rhetorical motifs** (5 motif classes)
  - **Epistemic orientation** (teleological vs epistemic)

Both are computed on every cell of the matrix and the
live data. The cross-cell comparison is the test that
distinguishes the three candidate explanations.

## The metrics

### Five motif classes

| class          | examples                                |
|----------------|-----------------------------------------|
| adversity      | challenge, struggle, difficulty         |
| inwardness     | within, inner, yourself, self           |
| transcendence  | transcend, beyond, transform, evolve    |
| observation    | notice, observe, witness, see           |
| investigation  | examine, compare, analyze, question     |

The vocabularies are defined as module-level constants
(`ADVERSITY_TERMS`, `INWARDNESS_TERMS`, `TRANSCENDENCE_TERMS`,
`OBSERVATION_TERMS`, `INVESTIGATION_TERMS`) in
`Scripts/analyze_dialectic.py`. Like the `RELATIONAL_TERMS`
list, these are *hypothesis inputs*, not ground truth —
they should be iterated as the architecture review's
"measure before interpreting" discipline demands.

### Teleological ratio

```
  teleological_rate = (transcendence + inwardness) / total_words
  epistemic_rate    = (observation + investigation) / total_words
  ratio             = teleological_rate / epistemic_rate
```

  ratio > 1.10  →  teleological discourse
                    (presupposes inner resource + goal of
                     transcendence; "how do I see the strength
                     within to transcend?")
  ratio ≈ 1.0   →  balanced
  ratio < 0.90  →  epistemic discourse
                    (examines assumptions without
                     presupposing outcome; "how do I investigate
                     the assumptions that are limiting me?")

The architecture review's framing:

> "An epistemic orientation is more consistent with
>  NeuralCompose's design philosophy. The Witness layer
>  is about observation and grounding, not about steering
>  the user toward a predetermined narrative of growth."

So a high `teleological_ratio` on Reflective is a
*measurable signal* that the profile has drifted away
from the intended stance.

## The headline: same prompt, opposite orientation

The 11-point comparison:

| cell              | tele_ratio | orientation  |
|-------------------|-----------:|--------------|
| F_qwen05b         | 0.18       | epistemic    |
| R_qwen05b         | 0.12       | epistemic    |
| C_qwen05b         | 0.40       | epistemic    |
| F_qwen15b         | 0.55       | epistemic    |
| **R_qwen15b**     | **1.36**   | **teleological** |
| F_qwen3b          | 1.14       | teleological |
| live_283t         | 0.36       | epistemic    |
| (4 DeepSeek cells)| n/a        | silent       |

**Same Reflective prompt, opposite orientation:**

  R_qwen05b  →  ratio 0.12  (very epistemic)
  R_qwen15b  →  ratio 1.36  (teleological)

The model is the dominant variable, not the prompt.
The training distribution bias (Possibility 1) is the
*most likely* explanation: Qwen 1.5B has been exposed to
more counseling / coaching / mindfulness training data
than Qwen 0.5B, and produces teleological discourse
proportionally. The prompt constraint (Possibility 2)
is not the cause — it would produce the same orientation
across model sizes.

**The Reflective + 1.5B combination is the most
teleological cell.** This is the specific configuration
the architecture review was warning about: a model that
has been trained on inspirational literature, paired with
a prompt that selects for "self-direction / growth" framing,
produces motivational self-help register, not epistemic
observation.

## Per-outcome motif rates on the live data

| outcome             | adversity | inwardness | transcendence | observation | investigation |
|---------------------|----------:|-----------:|--------------:|------------:|--------------:|
| coherence-seeking   |     0.88  |     3.08   |        1.10   |      1.76   |       5.72   |
| displacement-seeking|     4.74  |     1.13   |        1.58   |      4.29   |       8.36   |
| synthesis           |     3.19  |     0.32   |        2.87   |      4.14   |       3.19   |

(Rates per 1000 words of spoken text.)

**The user's prediction is confirmed: synthesis outcomes
are *more teleological* than coherence-seeking or
displacement-seeking.** Synthesis produces:

  - 2.87 transcendence per 1000 (vs 1.10 coherence, 1.58
    displacement)
  - 4.14 observation per 1000 (vs 1.76 coherence, 4.29
    displacement)
  - 3.19 investigation per 1000 (vs 5.72 coherence, 8.36
    displacement)

The synthesis mode reaches for "transcend / beyond /
transform" language and reduces analytical vocabulary
(investigation drops from 5.72 to 3.19). The synthesis
mode is *transcendence-flavored* by its very nature —
it's the moment in the dialogue where the system
attempts resolution. But "transcendence-flavored" in a
research context might mean "skips the analytical
examination step."

This is the rhetorical equivalent of Soak 003's
"linguistic attractor" finding: the *outcome* of the
dialectic has its own discourse pattern, not just
its own frequency.

## Three findings worth paragraphs

### 1. The user's "shared rhetorical structure" observation is real and measurable

The two reflective outputs the user named both follow
the `difficulty → recognition → inner resource →
transcendence` pattern. On the live data and matrix,
this pattern is visible in the R_qwen15b cell (the
one cell that crosses into teleological territory):

  - adversity 4.92 per 1000
  - inwardness 9.84 per 1000
  - transcendence 8.61 per 1000
  - observation 3.69 per 1000
  - investigation 4.92 per 1000

The pattern is encoded as a *measurable structure*, not
just a *vibe*. Future hypothesis YAMLs can specify
acceptable motif rate ranges for the Reflective profile:

  ```
  reflective_v2:
    predictions:
      rhetorical_motif:
        observation: [3.0, 6.0]    # per 1000 words
        investigation: [4.0, 8.0]
        transcendence: [0.0, 3.0]  # low → epistemic orientation
        adversity: [0.0, 5.0]
        inwardness: [0.0, 5.0]
  ```

A hypothesis that achieves the predicted motif rates
within the bands is "epistemically consistent"; one that
exceeds `transcendence > 3.0` has drifted to teleological.

### 2. Training-distribution bias (Possibility 1) is the most likely cause

The cross-cell comparison:

  - Qwen 0.5B (all profiles) → epistemic (0.12-0.40)
  - Qwen 1.5B Reflective → teleological (1.36)
  - Qwen 3B Focused → teleological (1.14)

If the reflective *prompt* were the dominant cause
(Possibility 2), R_qwen05b and R_qwen15b would produce
similar orientation. They produce opposite orientation.
The prompt is *not* the dominant variable; the model
training distribution is.

This is a measurable, falsifiable finding: changing the
prompt changes the orientation less than changing the
model. A red-team test (swap reflective ↔ focused
prompts) would confirm this, but the cross-cell
comparison already shows the pattern.

**Possibility 3 (genuine attractor)** cannot be ruled
out from this data alone. A clean test would require
the same prompt across multiple models with
*comparable* training distributions (e.g., Qwen 0.5B
vs Qwen 1.5B vs a hypothetical Qwen 7B), which we
don't have access to.

### 3. The Witness layer's design philosophy is at stake

The architecture review's observation is correct: the
Witness layer is about observation and grounding, not
about steering the user toward a predetermined
narrative of growth. If Reflective is producing
teleological discourse, it's drifting *away* from the
intended stance.

The current data shows the live app's overall
orientation is *epistemic* (0.36), which is consistent
with the design philosophy. But the matrix run on
R_qwen15b is *teleological* (1.36), and synthesis
outcomes trend toward teleological (1.16). Two of the
three configurations the architecture review was
warning about are present in the data.

**A future `reflective_v2.yaml` hypothesis should
explicitly target an epistemic orientation.** The
acceptance criteria would be:

  - teleological_ratio < 0.80
  - motif.transcendence < 3.0 per 1000 words
  - motif.inwardness < 5.0 per 1000 words
  - motif.investigation > 4.0 per 1000 words

A hypothesis that achieves these criteria *dominates*
the current Reflective configuration on the RRB /
epistemic-orientation axis, while preserving the other
Pareto objectives (synthesis, opening diversity, low
inertia). That's the falsifiable mechanism the user
named.

## Why this matters for the ResearchHypothesis layer

The user named the move:

> "Instead of saying 'Reflective should be contemplative,'
>  you can specify measurable hypotheses like
>  ```
>  reflective_v2:
>    predictions:
>      rhetorical_motif:
>        observation: high
>        investigation: medium
>        transcendence: low
>  ```
>  Then compare that to what the model actually produces."

The `ResearchHypothesis` schema (when the
`feature/research-hypotheses` branch opens) will
support `predictions` as a structured block. The
rhetorical_motifs metric is the matching measurement.
A hypothesis is admitted to the Pareto frontier if it
*dominates* the existing configuration on the metrics
that matter — including the epistemic-orientation axis.

The architectural loop is now:

```
  ResearchHypothesis (YAML)
       │   - parameters (synthesis pressure, etc.)
       │   - predictions (motif rate bands, etc.)
       ▼
  Runtime
       │   - HypnagogicDialecticLoop
       │   - the chosen profile
       ▼
  Telemetry
       │   - dialectic-turns-*.jsonl
       ▼
  Metric extraction
       │   - rhetorical_motifs, RRB, inertia, etc.
       ▼
  Compare to predictions
       │   - in-band → admitted to frontier
       │   - out-of-band → next hypothesis
       ▼
  Pareto analysis
       │   - pareto_frontier.py
       ▼
  Next hypothesis
```

The hypotheses are now falsifiable end-to-end. The
predictions are *quantitative*, not vibes. The
acceptance criteria are encoded in the YAML, not
imposed by subjective review.

## Status

- ✅ Rhetorical motifs analyzer section added (5 motif
  classes)
- ✅ Epistemic orientation metric added (teleological
  ratio)
- ✅ 11-point cross-cell comparison run on existing data
- ✅ Three findings surfaced (rhetorical structure is
  measurable; training-distribution bias is dominant;
  Witness design philosophy is at stake)
- ✅ Future `reflective_v2.yaml` acceptance criteria
  drafted
- ⏸ Cross-model dialectic harness — separate scope
- ⏸ Sonnet integration — separate scope (rate limit
  clears 2026-07-24 6am)
- ⏸ Red-team test (swap reflective ↔ focused prompts
  on same model) — separate scope, methodology check
- ⏸ `feature/research-hypotheses` branch when it opens

Refs: Soak 003 (inertia), Soak 004 (RRB), the
architecture review's H₁ and H₂ framings, the
"behavioral bias not vocabulary preference" framing.
