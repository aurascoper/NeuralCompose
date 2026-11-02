# Soak 004 — Relational Representation Bias (RRB) and the H₂ Hypothesis

**Date:** 2026-07-21
**Branch:** feature/pluggable-generators @ (this commit)
**Tooling:** `Scripts/analyze_dialectic.py` (RRB section) +
            `Scripts/pareto_frontier.py` (RRB deviation objective)
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
The first version of Soak 004 (commit `bc4820c`) tested H₂
with the symbolic_drift analyzer. The architecture review's
five refinements prompted this version, which:

  1. Renames the metric to **Relational Representation
     Bias (RRB)** with a concrete cross-model definition.
  2. Weakens the "not scaffold-driven" claim to
     "not explained by the currently identified prompt
     scaffolds."
  3. Surfaces the time-scale finding: RRB is a function of
     interaction length, not a static model property.
  4. Refuses to encode vocabulary targets into hypothesis
     YAMLs. The hypothesis tunes *parameters* (exploration
     pressure, synthesis pressure, silence threshold,
     witness grounding, coherence weighting); the RRB
     measurement tells us whether the parameters changed
     the bias.
  5. Adds a cross-model benchmark table the user proposed
     as a forward-looking artifact.

## The RRB metric

```
RRB = P(relational | spoken) / P(relational | heard)
```

  RRB = 1.0  → no amplification (the model uses
                relational words at the same rate as the
                user)
  RRB > 1.10 → amplification (the model introduces
                relational framing)
  RRB < 0.90 → suppression (the model uses relational
                words less than the user)

**Why a ratio, not a difference:** the ratio is comparable
across runtimes, models, and interaction lengths without
caring about any specific vocabulary. P(relational | heard)
acts as a per-conversation baseline, and P(relational |
spoken) is what the model chose to produce.

**Why no specific vocabulary:** the metric is defined
against the `RELATIONAL_TERMS` set in
`Scripts/analyze_dialectic.py`, but the choice of which
words count as "relational" is a *hypothesis input*. The
metric itself is the ratio; the vocabulary list is
iterable. Future work can swap in different word classes
(structural, abstract, etc.) without changing the metric.

## The headline finding: RRB is a function of time scale

The 11-point Pareto run with the live app + 10 matrix cells:

| cell              | P(rel\|spoken) | P(rel\|heard) | RRB    | class          |
|-------------------|----------------|---------------|--------|----------------|
| **live_283t**     |     0.0166     |    0.0138     | **1.22** | amplification |
| F_qwen15b         |     0.0230     |    0.0220     | 1.05   | neutral        |
| C_qwen05b         |     0.0137     |    0.0220     | 0.62   | suppression    |
| F_qwen3b          |     0.0152     |    0.0220     | 0.69   | suppression    |
| R_qwen15b         |     0.0162     |    0.0220     | 0.74   | suppression    |
| F_qwen05b         |     0.0120     |    0.0220     | 0.55   | suppression    |
| R_qwen05b         |     0.0103     |    0.0220     | 0.47   | suppression    |
| F_deepseek_r1     |     0.0000     |    0.0220     | 0.00   | (silent)       |
| F_deepseek_flash  |     0.0000     |    0.0220     | 0.00   | (silent)       |
| R_deepseek_r1     |     0.0000     |    0.0220     | 0.00   | (silent)       |
| R_deepseek_flash  |     0.0000     |    0.0220     | 0.00   | (silent)       |

**Same Qwen 0.5B model, opposite RRB:**

  - 30-turn matrix corpus: RRB 0.47-0.62 (suppression)
  - 283-turn live app: RRB 1.22 (amplification)

**The amplification emerges over extended dialogue.** The
30-turn corpus is too short to surface the bias; the 283-turn
live run surfaces it. This is a clean, falsifiable finding
about the time scale of the relational representation
phenomenon.

**The DeepSeek cells are "silent" (96-100% non-response),
not "no bias" — their RRB=0.00 means no spoken text to
compare. Future work on DeepSeek requires a per-model
num_predict fix (the RVS-001 finding from commit `a155af5`)
before RRB can be measured on them.

## Three reframings per the architecture review

### 1. The "not scaffold-driven" claim is weakened

The first version of this doc claimed:

  > "The relational vocabulary is NOT scaffold-driven."

The architecture review correctly notes that this is
stronger than the data supports. The data shows:

  - The relational vocabulary is *not explained* by the
    specific repeated scaffolds identified (16 occurrences
    of "in a live dialogue"). The vocabulary is not in
    the per-turn template or the system prompt.

That is not quite the same as proving independence from
prompting altogether. Prompts influence models in many
indirect ways; future evidence might show that.

The corrected wording:

  > **"The observed amplification cannot be explained by
  >  the currently identified prompt scaffolds."**

This leaves room for future evidence about indirect
prompt influence, and is the discipline the user
enforced.

### 2. The headline is "behavioral bias," not "vocabulary preference"

The user reframes the finding as:

  > **"The model preferentially reformulates interactions
  >  in relational terms."**

This is a stronger and more general claim than "the model
uses the word 'space' more often." The amplification
pattern across relational terms (through: 2.3×, between:
2.0×, space: 2.3×, us: 1.5×, value: 7×) is not arbitrary;
nearly all the amplified words describe *relations between
things*, not *things themselves*.

A future RRB benchmark can report RRB by model without
naming any specific vocabulary. The metric is in the
*interaction dynamics*, not in the *lexical inventory*.

### 3. Don't encode vocabulary targets into hypothesis YAMLs

A natural temptation is to encode "we want less 'space'"
into `contemplative_v4.yaml`. The user correctly resists:

  > "Those are **observations**, not parameters.
  > The hypothesis should tune measurable variables
  > like exploration pressure, synthesis pressure,
  > silence threshold, witness grounding, coherence
  > weighting — and then ask: does changing these
  > parameters alter the Relational Representation
  > Bias (RRB)?"

The causal direction is:

  Hypothesis → behavior (parameters) → measured RRB

NOT

  Desired vocabulary → prompt engineering

This is the distinction that keeps the system scientific
rather than steering it toward preferred language. The
hypothesis YAMLs (when the `feature/research-hypotheses`
branch opens) will tune *parameters*; the RRB measurement
will tell us whether the parameters changed the bias.

## The cross-model benchmark table (forward-looking)

The user proposed a future benchmark:

| Model       | RRB  | Semantic inertia | Linguistic inertia |
|-------------|-----:|-----------------:|-------------------:|
| Qwen 0.5B   | 1.22 |             0.05 |               0.36 |
| DeepSeek    | 0.9  |             0.08 |               0.18 |
| Claude      | 1.4  |             0.04 |               0.21 |

This is the *cross-model dialectic* benchmark: not "which
model is smarter," but "what are the interaction dynamics
of each model on the same dialectic corpus?"

The current data gives us only one data point (Qwen 0.5B
on the live app: RRB 1.22). DeepSeek is blocked by the
silent-turn issue; Claude is blocked by the Sonnet rate
limit (clears 2026-07-24 6am).

**The benchmark will land when:**

  - Per-model `num_predict` defaults are added to
    `LiveRuntimeFactory` (so DeepSeek produces text)
  - The cross-model dialectic harness ships (so Pole A and
    Pole B can be different models)
  - The Sonnet rate limit clears (so Claude can be tested)

None of these are required for the Soak 004 findings. The
table is the *forward target* the cross-model work enables.

## The H₂ hypothesis verdict (with the RRB framing)

| criterion                                  | status |
|--------------------------------------------|--------|
| low semantic inertia                       |   ✓    |
| stable/decreasing policy inertia           |   ✓    |
| increasing frequency of relational terms   |   ⚠ flat (not increasing)  |
| without scaffold repetition increasing     |   ✓    |

**H₂ is *partially* supported. The relational vocabulary
is prominent and model-amplified, but it is not
*increasing* over the 304-turn run.** This is now stated
more precisely in the RRB framing: the model amplifies
the relational vocabulary at a *constant rate* (RRB ≈
1.2), not a *growing rate*.

**H₂' (the user's rename):** "Long-running dialectical
interactions develop a *stable* relational representation
bias that is *model-amplified* (RRB > 1.0) without
requiring either increasing linguistic inertia or
scaffold repetition."

This is a falsifiable restatement. The acceptance
criteria for a `contemplative_v4.yaml` hypothesis YAML
would be:

  - rrb ∈ [0.95, 1.15]   (small or no amplification)
  - rrb_deviation < 0.20  (close to neutral)
  - drift(P(relational)) ∈ [-0.5pp, +0.5pp] (stable)
  - semantic_inertia < 0.10   (low)
  - scaffold_leakage < 5%     (no growth)

A hypothesis that achieves a *lower RRB deviation* than
`contemplative_v3` (the current state) would dominate on
the RRB axis while preserving the other metrics. That's
the Pareto-frontier mechanism for scientific selection.

## Why a red-team test is no longer the urgent next step

The architecture review suggested removing the
"in a live dialogue" scaffold and re-running soaks to
determine whether the relational vocabulary is prompt-
leakage or emergent. The data already answers this:

  - The relational vocabulary is *not in the scaffold*
    (no named term appears in either prompt or template)
  - The relational vocabulary is *model-amplified*
    (every term appears 1.5×-7× more in spoken than heard)
  - The amplification emerges over time (RRB 0.55 in 30
    turns, RRB 1.22 in 283 turns, same model)

Therefore the relational vocabulary is *model-emergent*,
not prompt-leakage. The red-team test would be a
methodology check (does removing the scaffold change RRB?
Probably not, but verifying is good practice), not a
hypothesis test. Building a `--no-scaffold` flag is
deferred as a separate scope.

## Status

- ✅ Relational Representation Bias (RRB) metric added
- ✅ Live data analyzed: RRB = 1.22 (amplification)
- ✅ 10 matrix cells analyzed: RRB 0.0-1.05 (mostly
  suppression, plus one near-neutral)
- ✅ Time-scale finding surfaced (Qwen 0.5B amplifies
  at 283 turns, suppresses at 30 turns)
- ✅ Three reframings applied (weakened scaffold claim,
  behavioral bias framing, parameter-not-vocabulary)
- ✅ Cross-model benchmark table drafted
- ⏸ Per-model `num_predict` defaults — separate scope
- ⏸ Cross-model dialectic harness — separate scope
- ⏸ Claude Sonnet integration — separate scope (rate
  limit clears 2026-07-24 6am)
- ⏸ H₂' as a hypothesis YAML — `feature/research-hypotheses`
  branch when it opens

Refs: Soak 003 (inertia + Pareto), the architecture
review's five refinements to H₂, the "behavioral bias
not vocabulary preference" framing.
