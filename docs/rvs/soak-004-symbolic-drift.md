# Soak 004 — Symbolic Drift and the H₂ Hypothesis

**Date:** 2026-07-21
**Branch:** feature/pluggable-generators @ b9b902a
**Tooling:** `Scripts/analyze_dialectic.py` (new symbolic_drift section)
**Data:** 304 live turns + 10 matrix cells × 30 turns

This is the fourth post-soak findings doc. The architecture
review named two testable questions:

  H₁: Independent interaction policies converge on shared
      geometric metaphors because those metaphors efficiently
      describe latent-state dynamics.

  H₂: As a stable dialectical interaction matures, lexical
      content shifts from object-centered vocabulary toward
      relational vocabulary while semantic inertia remains
      low.

The Soak 003 findings doc added the inertia decomposition
(semantic / linguistic / policy) and the Pareto frontier.
This doc adds the symbolic_drift analyzer section
(`Scripts/analyze_dialectic.py`) and runs it on the existing
data to test H₂.

**Why this is "measure before interpreting":**

The reviewer's framing — "lexical convergence vs structural
convergence" — was the right question to ask. Several of the
relational terms the user named (`space`, `us`, `value`, `sign`,
`between`, `through`) show up in the live data. Before
concluding they are "emergent" or "leakage," the question is
*where they come from.* The data can answer that without any
new code.

## Findings

### 1. The relational vocabulary is *real*, not zero

Top relational terms in the spoken text of 304 live turns:

| word    | spoken count |
|---------|--------------|
| through |     23       |
| us      |     19       |
| between |     14       |
| value   |     11       |
| space   |     10       |
| context |      9       |
| within  |      7       |
| field   |      6       |
| toward  |      5       |
| together|      4       |

These are not prompt-leaked. The system prompt
(`Sources/BCICloudBridge/Prompts/waking-dialectical.md`)
contains "live, waking dialectical exchange" but not any
of the user's named terms. The per-turn scaffold
("In a live dialogue, the other person just said:")
also does not contain them. **The relational vocabulary
is emerging from the model itself, not from the prompt.**

### 2. The relational vocabulary is *model-amplified*, not user-driven

Compared against the user-driven heard lines:

| word    | heard (turns) | spoken (turns) | ratio |
|---------|---------------|----------------|-------|
| together|       0       |       4        |   ∞   |
| value   |       1       |       7        |  7.0× |
| field   |       1       |       6        |  6.0× |
| toward  |       1       |       5        |  5.0× |
| context |       3       |       9        |  3.0× |
| space   |       4       |       9        |  2.3× |
| between |       7       |      14        |  2.0× |
| through |      10       |      23        |  2.3× |
| us      |      13       |      20        |  1.5× |

Every relational term appears *more often* in the model's
spoken text than in the user's heard lines, with ratios
from 1.5× (us) to 7× (value) to infinite (together, which
appears 0 times in heard and 4 times in spoken).

**This is a measurable, model-driven amplification of
relational vocabulary.** Qwen 0.5B reaches for relational
words as natural connectors in its generated text, even
when the user is talking about other things. This is
neither prompt leakage (the words aren't in the prompt)
nor user-driven (the user doesn't use them as much).

### 3. The H₂ hypothesis is *partially* supported, but not as predicted

The first-half / second-half drift in P(relational) /
P(object) / P(process):

| class     | first-half | second-half | drift (pp) |
|-----------|------------|-------------|------------|
| relational|   1.57%    |   1.66%     |  +0.09 ↑   |
| object    |   0.75%    |   0.35%     |  -0.40 ↓   |
| process   |   0.90%    |   0.35%     |  -0.55 ↓   |

H₂ predicted:
  - low semantic inertia ✓ (0.049 on live data)
  - stable/decreasing policy inertia ✓ (0.273)
  - increasing frequency of relational terms ⚠ (drift is +0.09pp;
    essentially flat, well below the threshold for "increasing")
  - without an accompanying increase in scaffold repetition ✓
    (scaffold count is stable at 16-18)

The predicted *direction* of relational drift is not
visible at the time scale of 304 turns. P(relational) is
*flat*, not increasing. **But P(object) and P(process) are
both decreasing by ~50%**, which is consistent with the
broader pattern: the corpus is losing content words
across all classes except the relational one.

This is consistent with the Soak 003 attractor finding
(linguistic_inertia 0.365): the system is converging
toward a small set of relational scaffolds, not because
the model is producing more relational words, but because
it's producing *less of everything else*.

### 4. The "in a live dialogue" scaffold is a *separate* phenomenon

The dominant leak in the live data is the per-turn scaffold
`In a live dialogue, the other person just said:` (16
occurrences out of 304 turns, 5.3%). This is *not* in the
user's named relational vocabulary. It is a different
attractor: the prompt's wrapper text being reproduced by
the model as part of the response.

**These are two distinct linguistic attractors:**

  - The "in a live dialogue" scaffold (16 turns) is
    prompt leakage. The fix is in the prompt template.
  - The relational vocabulary (through, us, between,
    value, space) is model-driven amplification. The
    fix is in the model selection or in additional
    prompt guidance to use object / process vocabulary.

The architecture review's "lexical vs structural convergence"
question has a clean answer for the live data:

  - The model's relational vocabulary is *structural* —
    it's a feature of Qwen 0.5B's output distribution,
    not a copy of the prompt.
  - The "in a live dialogue" scaffold is *lexical* —
    it's a verbatim prompt fragment that the model is
    reproducing as part of its response.

These are two different things, both measurable, with
different fixes.

### 5. P(other) is 98%+ — the vocabulary lists are partial

The total proportion of words that match *any* of the
three vocabulary classes is ~3% on the live data
(1.66% relational + 0.35% object + 0.35% process +
~0.7% other small categories). The other 97% is the
general English vocabulary the user named as
"not relational / not object / not process" — articles,
prepositions, common verbs (be, have, do, see, make,
take), and the general descriptors (real, change, like,
feel, think, know).

This is a healthy finding. The vocabulary lists are
*intentionally* narrow: they capture the *user-named*
classes of interest, not the full lexical distribution.
A drift signal in these classes is meaningful precisely
*because* the classes are narrow.

## The H₂ hypothesis verdict (preliminary)

| criterion                                  | status |
|--------------------------------------------|--------|
| low semantic inertia                       |   ✓    |
| stable/decreasing policy inertia           |   ✓    |
| increasing frequency of relational terms   |   ⚠ flat (not increasing)  |
| without scaffold repetition increasing     |   ✓    |

**The H₂ prediction is half-right.** The dialogue does
maintain a relational vocabulary while semantic inertia
stays low and scaffold repetition stays constant. But
the relational vocabulary is *not* increasing — it's
*amplified by the model* (1.5×-7× more than the user
produces) but at a roughly constant rate over time.

A more accurate restatement of the finding:

  **H₂':** Long-running dialectical interactions develop
  a *stable* relational vocabulary that is *model-amplified*
  (the model uses relational words more than the user
  does) without requiring either increasing linguistic
  inertia or scaffold repetition.

This is a falsifiable refinement. The next test (a
hypothesis YAML on the `feature/research-hypotheses`
branch) would specify the expected proportions:

  - P(relational) ∈ [0.5%, 2.0%]  (model-amplified, stable)
  - P(object) ∈ [0.2%, 1.0%]      (declining over time)
  - P(process) ∈ [0.2%, 1.0%]     (declining over time)
  - drift(P(relational)) ∈ [-0.5pp, +0.5pp] (stable)
  - semantic_inertia < 0.10         (low)
  - scaffold_leakage < 5%          (no growth)

## Status

- ✅ Symbolic drift analyzer section added
- ✅ Live data analyzed: relational vocabulary is real,
  model-amplified, stable (not drifting)
- ✅ The H₂ hypothesis is half-supported; H₂' refinement
  is proposed
- ⏸ Red-team test (--no-scaffold) — *not* yet built;
  rationale: the data already shows relational vocabulary
  is *not* scaffold-driven, so a red-team test would
  only confirm what the heard-vs-spoken ratio already
  shows. Still worth doing as a methodology check.
- ⏸ H₂' as a hypothesis YAML — future branch
- ⏸ Cross-model dialectic — separate scope

Refs: Soak 003 (inertia + Pareto), the architecture
review's H₁ and H₂ framings, the architecture review's
"measure before interpreting" discipline.
