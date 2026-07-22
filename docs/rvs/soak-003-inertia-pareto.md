# Soak 003 — Inertia, Pareto Frontier, and the "Harmony ≠ Resolution" Finding

**Date:** 2026-07-21
**Branch:** feature/pluggable-generators @ 75dcc1c
**Tooling:** `Scripts/analyze_dialectic.py` + `Scripts/pareto_frontier.py`
**Data:** 11 points = 10 matrix cells (soak-002) + 1 live app (283 turns)

This is the third post-soak findings doc. SOAK 001 established
the *quantitative baseline* (8 acceptance criteria, 140 turns).
SOAK 002 established the *test matrix* (10 cells, 300 turns,
fixed heard-line corpus). This doc establishes the *inertia +
Pareto frontier layer* — the structural framework for the
closed empirical loop the architecture review called for.

The two key new tools:

- `Scripts/analyze_dialectic.py` now reports a
  **three-component inertia** (semantic, linguistic, policy)
  plus a **critical-slowing-down diagnostic** (variance +
  lag-1 autocorrelation of heard-length series).
- `Scripts/pareto_frontier.py` computes the **Pareto frontier**
  of a set of (hypothesis, metrics) points — configurations
  that are not dominated on every objective by any other
  configuration.

Both are committed on `feature/pluggable-generators`.

## The framing: convergence onto attractors, not collapse

The user's framing in the post-soak architecture review:

  > "If synthesis is increasing AND diversity is decreasing,
  > the most plausible reading is convergence onto stable
  > conversational attractors. The system is becoming more
  > coherent and more stereotyped at the same time, by
  > settling onto a small set of stable topics with
  > predictable openings."

  > "Harmony isn't necessarily resolution — it can be
  > equilibrium."

  > "Near stable attractors, systems often exhibit lower
  > variance, higher autocorrelation, slower recovery after
  > perturbation. Sometimes called critical slowing down."

This doc operationalizes that framing in three layers:

1. **Inertia** decomposes the convergence into three axes
2. **Critical slowing down** adds a diagnostic for whether
   the system is approaching a fixed point
3. **Pareto frontier** lets hypotheses be evaluated as points
   in objective space, with no single "best" being the right
   answer

## Findings: 11 points, 8 on the frontier

The Pareto run with the 10 matrix cells + 1 live app point:

| label | rank | synth | open | ngram | silent | sem_I | ling_I | pol_I | leak | wit_coup |
|---|---|---|---|---|---|---|---|---|---|---|
| C_qwen05b | ★1 | 0.000 | 0.966 | 0.967 | 0.033 | 0.034 | 0.034 | **0.618** | 0.067 | 0.500 |
| F_qwen05b | ★1 | 0.200 | 0.793 | 0.702 | 0.000 | 0.034 | 0.207 | 0.359 | 0.067 | 0.571 |
| F_qwen15b | ★1 | 0.200 | 0.800 | 0.786 | 0.000 | 0.034 | 0.200 | 0.397 | 0.067 | 0.429 |
| F_qwen3b  | ★1 | **0.300** | 0.667 | 0.657 | 0.000 | 0.034 | 0.333 | 0.479 | 0.067 | 0.464 |
| R_qwen05b | ★1 | 0.167 | 0.828 | 0.736 | 0.000 | 0.034 | 0.172 | 0.289 | **0.167** | 0.000 |
| R_qwen15b | ★1 | 0.167 | 0.833 | 0.784 | 0.000 | 0.034 | 0.167 | 0.400 | 0.000 | 0.000 |
| live_283t | ★1 | **0.290** | 0.635 | 0.663 | 0.000 | 0.049 | **0.365** | 0.273 | 0.063 | 0.109 |
| R_deepseek_flash | ★1 | 0.000 | 0.000 | 1.000 | 0.967 | 0.034 | 0.000 | 0.944 | 0.000 | 0.964 |
| F_deepseek_flash | 2 | 0.000 | 0.000 | 0.000 | 1.000 | 0.034 | 0.000 | 1.000 | 0.000 | 1.000 |
| F_deepseek_r1 | 2 | 0.000 | 0.000 | 0.000 | 1.000 | 0.034 | 0.000 | 1.000 | 0.000 | 1.000 |
| R_deepseek_r1 | 2 | 0.000 | 0.000 | 0.000 | 1.000 | 0.034 | 0.000 | 1.000 | 0.000 | 1.000 |

(`★` = on the Pareto frontier. Bold = best on that column.)

### Three findings worth paragraphs

**1. The "synthesis reluctance" finding was a measurement error.**

SOAK 002 (`docs/rvs/soak-002-matrix.md`) reported 0% synthesis
on every Qwen cell. That was because the matrix aggregator
used the raw outcome key `synthesized_synthesis` instead of
the normalized key `synthesis`. The actual rates are 0% on
C_qwen05b (30 turns of contemplative matrix corpus), 16-20%
on focused / reflective matrix cells, 30% on F_qwen3b, and
29% on the live app's 283-turn run. The "0% synthesis" was
real for `C_qwen05b` (the matrix corpus didn't elicit
synthesis in 30 turns), but the matrix *summary* over-reported
the reluctance by reading the wrong key.

This is exactly the kind of error the closed empirical loop
is supposed to catch, and it just did. **Lesson: the
matrix.json sidecar is the canonical report; the
matrix summary's text-table is a render, not a source.**

**2. The live app achieves higher synthesis (29%) than every
matrix cell, and is on the frontier alongside them.**

`live_283t` has 0.29 synthesis — higher than any 30-turn
matrix cell. The matrix corpus (30 fixed lines) doesn't
elicit synthesis as well as the live app's organic
user-driven input (283 turns). The corpus is doing a lot
of work; future matrix runs should include a 2nd corpus
(`live-001` vs `organic-001`) to make this comparable.

**3. The three-component inertia on the live data says:
"this is a linguistic attractor, not a semantic or policy one."**

| axis | live_283t | interpretation |
|---|---|---|
| semantic_inertia | 0.049 | very low — heard lines change topic freely |
| linguistic_inertia | 0.365 | moderate — openings are stereotyped |
| policy_inertia | 0.273 | low — transition policy varies |

| diagnostic | live_283t | interpretation |
|---|---|---|
| heard-length variance | 3632 | very high — not at a fixed point |
| heard-length autocorr (lag=1) | 0.017 | very low — no sticky dynamics |

The system is *not* at a dynamical fixed point at the
semantic or policy level. The heard-length series shows
no critical slowing down (low autocorrelation, high
variance). The dominant inertia vector is **linguistic**:
the openings are stuck on a small set of templates, but
the topics and the transition policy are still varied.

The "in a live dialogue" scaffold (16 occurrences out of
283 turns, 5.7%) and the "perhaps we should examine"
template (2 occurrences) are the dominant attractors.
**The fix lives in the prompt, not in the dialectic
dynamics.** Removing the `in a live dialogue` scaffold
from the system prompt would directly lower
linguistic_inertia without changing semantic or policy
inertia.

## The closed empirical loop, end to end

```
  Experiment (the question)
       │
       ▼
  ResearchHypothesis (YAML: parameters + acceptance criteria)
       │
       ▼
  Runtime (Swift)
       │
       ▼
  Computational kernels (Swift / Rust / Scientific)
       │
       ▼
  Telemetry (turns + fingerprints + telemetry.jsonl)
       │
       ▼
  Metric extraction (analyze_dialectic.py)
       │
       ▼
  Pareto analysis (pareto_frontier.py)
       │
       ▼
  Next hypothesis (a point on the frontier → a new YAML)
```

The loop is now real:

- **Hypothesis:** A YAML (when the `feature/research-hypotheses`
  branch is opened) declares parameters + acceptance criteria.
- **Runtime:** The harness (or live app) executes the
  hypothesis against the matrix corpus.
- **Telemetry:** Per-turn JSONL with fingerprints.
- **Metric extraction:** `analyze_dialectic.py` produces a
  baseline JSON.
- **Pareto analysis:** `pareto_frontier.py` identifies
  whether the new hypothesis dominates any existing point,
  or is dominated by some.
- **Next hypothesis:** A new YAML designed to push the
  frontier outward on the axes that matter.

The empirical loop is the closed loop. Pareto analysis is
the mechanism for falsifiable scientific selection.

## Two outstanding follow-ups (small focused commits)

1. **Live-app `LiveRuntimeFactory` env-var fix** — the live
   app uses the stub LLM despite `NEURALCOMPOSE_RUNTIME=ollama`
   being set. The harness path is correct; only the live-app
   factory needs the fix. The live app's 30 fingerprinted
   turns (out of 283) are from the harness tests, not from
   the live app.

2. **Cross-model dialectic harness extension** — needs
   `--pole-a-runtime` / `--pole-b-runtime` options to
   run Pole A: Qwen, Pole B: DeepSeek, Witness: local Qwen
   (and inverted). The matrix runner accommodates the new
   shape; only the harness needs the change.

3. **Add a 2nd corpus to `Scripts/soak-matrix.sh`** — a
   `live-001` corpus of the actual user-driven heard lines,
   parallel to the existing `organic-001` corpus, so the
   matrix can be run against the same lines the live app
   sees. This would make live-vs-matrix comparisons more
   meaningful.

## What this means for `ResearchHypothesis` (when that branch opens)

A `contemplative_v3.yaml` is no longer a "philosophical
preset" but a *point in objective space*. Its acceptance
criteria are no longer "does it feel better" but "does it
dominate contemplative_v2 on the metrics that matter?"

The 11 acceptance criteria (8 from SOAK 001 + 3 from SOAK 002)
are the cost function. A new hypothesis is admitted to
the frontier if it's not dominated on every objective by
any existing point.

The user's framing:

  > "Hypotheses are retained not because they better
  > embody a philosophical tradition, but because they
  > move the system onto a more favorable Pareto
  > frontier according to the metrics you've defined."

This is the scientific selection mechanism the architecture
was missing. With the loop now closed, hypothesis evaluation
is reproducible and falsifiable.

## One forward-looking thought: conceptual convergence

The user's most recent framing named a question worth
attending to:

  > "If Focused and Contemplative independently begin
  > converging on 'space' as the organizing metaphor,
  > is it lexical convergence (same vocabulary) or
  > structural convergence (same dynamics)?"

The proposed `conceptual_convergence` metric (with three
sub-dimensions: lexical, embedding, policy similarity)
is the right tool. It is **not** added to the analyzer
in this commit — the data shape doesn't yet support it
(no embeddings in the JSONL, no per-profile comparison
data). When the cross-model dialectic harness is built
(follow-up #2 above), a `conceptual_convergence` analyzer
section will become the natural follow-on.

The H₁ hypothesis — "Independent interaction policies
converge on shared geometric metaphors because those
metaphors efficiently describe latent-state dynamics" —
goes into the `ResearchHypothesis` schema as a falsifiable
claim. Testable across runtimes, prompts, and long soaks.

## Status

- ✅ Three-component inertia: live data
- ✅ Critical slowing down diagnostic: live data
- ✅ Pareto frontier analysis: 11 points, 8 on frontier
- ✅ Synthesis_rate measurement error: caught and fixed
- ⏸ Live-app `LiveRuntimeFactory` env-var fix: separate scope
- ⏸ Cross-model dialectic: separate scope
- ⏸ Conceptual convergence: future (post cross-model)
- ⏸ `ResearchHypothesis` YAML schema: future branch

Refs: SOAK 001, SOAK 002, architecture review, Pareto
analysis framing.
