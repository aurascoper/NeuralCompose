# Research

This document describes the planned research program for the platform. It is
the pre-registration companion to `SLEEP_CYCLE_DESIGN.md` §14 — i.e. the plan
for **D8**, the eighth and final module of the D1–D8 sleep-cycle design: the
pilot human evaluation study (§14). ("D" is a design-deliverable index; "D8"
here is **not** the BCI senses of the term — not an 8-direction pathing
algorithm, an 8-channel electrode array, or a downsample-by-8 layer.) The
platform is the engineering contribution; this is the empirical one.

## Research Question

Does AI-assisted cognitive incubation during sleep (LLM-generated dream
incubation, hypnagogic-state audio cues, TMR during N2/SWS, hypnopompic wake,
LLM dream-report analysis) improve post-sleep creative problem solving
compared to natural sleep?

This is **unproven**. The individual components have varying levels of
support: TMR for declarative memory is established; TMR for creative insight
is plausible but unproven; LLM-assisted dream analysis is novel. The
research program exists to test the integrated pipeline, not to validate
pre-conclusions.

## Why a Pilot Feasibility Study First

Before scaling to a definitive trial, the platform itself must be
operationally viable:

1. Can a Muse S be worn for 4+ hours without losing contact or exhausting the battery?
2. Can the 4-class sleep-stage classifier produce stable predictions on per-user data?
3. Can the LLM primer generation and dream analysis complete within latency budgets?
4. Can the safety constraints (audio cap, TMR budget, abort paths) be enforced in code?
5. Can a session run end-to-end without crashes?

These are engineering questions, not research questions. They are gated by the Sleep Validation Toolkit (Phase B) before D8 begins.

## Pre-Registration

The full D8 analysis plan must be registered on **OSF** (or equivalent) before data collection begins. Pre-registration is non-negotiable. Without it, the results are anecdotal.

The pre-registration will specify:

- The four hypotheses (H1–H4) as testable null/alternative pairs.
- The within-subject crossover design with three conditions.
- The sample size N = 30 (target) with N = 20 minimum for d = 0.5 detection.
- The outcome measures: novelty (primary), dream-relevance, LLM-human rater agreement.
- The statistical analysis plan: repeated-measures ANOVA, paired t-tests with Bonferroni, Cohen's d with 95% CI, Bayes factors.
- The stopping criteria: interim analysis at N = 10 (futility at d < 0.1), max N = 40, harm stop at PSQI increase > 3.

## Hypotheses

### H1 (primary)

Participants who use the full incubation pipeline (primer + hypnagogic detection + TMR + dream report + LLM analysis) produce more novel solutions to a pre-registered engineering problem than participants who sleep normally.

- $H_0: \text{novelty}_{\text{active}} = \text{novelty}_{\text{control}}$
- $H_1: \text{novelty}_{\text{active}} > \text{novelty}_{\text{control}}$

Novelty is rated blind by 3 independent domain experts on a 5-point Likert scale. Inter-rater reliability is reported as Fleiss' κ.

### H2 (secondary)

The LLM-generated primer produces dream reports with higher problem-relevance than a static control primer.

- $H_0: \text{relevance}_{\text{LLM primer}} = \text{relevance}_{\text{static primer}}$
- $H_1: \text{relevance}_{\text{LLM primer}} > \text{relevance}_{\text{static primer}}$

### H3 (secondary)

Dream reports collected immediately after hypnopompic transition contain more actionable analogies than reports collected after a full night's sleep.

- $H_0: \text{actionable}_{\text{hypnopompic}} = \text{actionable}_{\text{natural}}$
- $H_1: \text{actionable}_{\text{hypnopompic}} > \text{actionable}_{\text{natural}}$

### H4 (secondary)

The LLM's analogy extraction from dream reports has non-trivial agreement with human raters.

- $H_0: \kappa_{\text{LLM-human}} = 0$
- $H_1: \kappa_{\text{LLM-human}} > 0.4$ (Cohen's κ, "moderate" agreement)

## Experimental Design

**Within-subject crossover.** Each participant serves as their own control.
Three conditions, each on a separate night, order counterbalanced via Latin
square:

1. **Active**: full pipeline — LLM primer, hypnagogic detection, TMR cue during N2, hypnopompic wake, dream report, LLM analysis.
2. **Sham**: same hardware setup, same primer playback, no TMR cue, no timed wake. Participant sleeps through the night, reports dreams upon natural waking.
3. **Control**: no hardware, no primer, normal sleep. Participant reports dreams upon natural waking.

**Washout period:** minimum 48 hours between conditions.

**Problem assignment:** each night gets a different engineering problem of comparable difficulty (pre-rated by 3 independent judges on a 1–5 scale; only problems within ±0.5 of mean difficulty are used).

## Sample Size

Power analysis: medium effect size (Cohen's d = 0.5), α = 0.05, β = 0.80, within-subject 3-condition design.

- Required N for primary H1: ~20 complete sessions.
- Attrition budget: 30–40%. Target enrollment: N = 30.
- Maximum enrollment: N = 40 (stopping criterion).
- This is a **pilot feasibility study**, not a definitive trial. The N = 20–30 range detects medium effects but with wide confidence intervals on the effect size itself.

## Outcome Measures

### Primary

**Novelty score of post-sleep solution to the engineering problem.**
Rated blind by 3 independent domain experts on a 5-point Likert scale.
Inter-rater reliability: Fleiss' κ.

### Secondary

- Dream report problem-relevance (rated blind by 3 raters).
- Number of distinct analogies extracted by LLM vs. human raters.
- Subjective sleep quality (PSQI + post-session questionnaire).
- Participant blinding check: post-session, ask which condition they believed they were in.

### Exploratory

- **Aperiodic-exponent (1/f slope) correlates.** Per [`Math.md` §11.2](Math.md), the aperiodic exponent $\chi$ during N2/SWS is a literature-backed, **pre-registerable** secondary hypothesis ($\chi$ ↔ insight quality — the aperiodic slope indexes E/I balance and varies across sleep stages), not a post-hoc theta correlation. Alpha dropout is computed aperiodic-adjusted ($r_\alpha^{\mathrm{corr}}$) so a broadband 1/f shift does not masquerade as an alpha change.
- **Automated novelty ($N_{\mathrm{PR}}$).** Per [`Math.md` §11.3](Math.md), report the participation-ratio novelty $N_{\mathrm{PR}}$ over the LLM-extracted analogy set as an automated companion to the blind human Likert (H1), and pre-register the Spearman $\rho$ between $N_{\mathrm{PR}}$-novelty and mean blind human novelty (reported beside H4's LLM–human agreement). $N_{\mathrm{PR}}$ catches paraphrastic near-loops that an exact-repeat count misses.
- Correlation between sleep stage duration and insight quality.
- LLM analysis accuracy vs. human rater agreement.

## Control for Confounds

| Confound | Control |
|----------|---------|
| Placebo effect | Sham condition (hardware + primer, no TMR / timed wake) |
| Order effects | Latin square counterbalance of condition order |
| Problem difficulty | Pre-rated problems, randomized assignment |
| Sleep quality | PSQI screening at enrollment; exclude diagnosed sleep disorders |
| Familiarity | Exclude problems the participant has worked on in past week |
| Time of night | Standardize session start time (±30 min) |
| Demand characteristics | "Free recall, no right answers" prompt; raters blind to condition |

## Statistical Analysis Plan

- **Primary analysis**: repeated-measures ANOVA (condition × outcome) with Greenhouse-Geisser correction.
- **Post-hoc**: paired t-tests with Bonferroni correction (3 comparisons).
- **Effect sizes**: Cohen's d with 95% CI.
- **Bayesian alternative**: Bayes factors for primary hypothesis (BF₁₀ > 3 as evidence for H1).
- **Pre-registration**: the full analysis plan must be registered on OSF before data collection begins.

## Stopping Criteria

- **Interim analysis** after N = 10 complete sessions: stop for futility if observed effect size d < 0.1.
- **Maximum enrollment**: N = 40 complete sessions.
- **Stopping for harm**: if any participant reports clinically significant sleep disruption (PSQI increase > 3 points) or any safety-relevant event, pause and review.

## Limitations to State Explicitly

- Small N (target N = 30, max N = 40) limits generalizability.
- Single-site, single-hardware (Muse S).
- Engineering problem-solving is a narrow domain; results may not transfer to other creative domains.
- The sham condition still involves wearing a headband, which may affect sleep quality differently from the no-hardware control.
- Dream reports are inherently subjective and may be influenced by demand characteristics.
- The LLM in the loop is a moving target; the system used at study start is not the system used at study end. Document the model version per session.
- **Cross-representation (EEG ↔ language) alignment is not analyzed at pilot N.** Per [`Math.md` §11.4](Math.md), with N ≈ 20–30 matched pairs and embedding dimension in the hundreds we are in the $n \not\gg d$ regime where CKA/SVCCA are unreliable; the EEG-latent ↔ solution-embedding coupling analysis is deferred to the definitive trial, or run only after reducing each space to $k \ll n$ dimensions (SVCCA $\tau$-truncation). Both Procrustes variants (scaled, orthogonal) are reported when it is run — they are not interchangeable.

## Open Research Questions Beyond D8

- **Multi-night pattern tracking.** Does insight accumulate over multiple sleep sessions?
- **Cross-domain transfer.** Do the effects (if any) generalize from engineering to math, design, writing?
- **Adaptive primer generation.** Can the LLM adapt the primer based on prior session outcomes?
- **TMR cue-stage optimization.** Is N2 or SWS the better cueing target for creative insight?
- **Dream content ↔ EEG stage correlation.** Can the EEG stage timeline predict dream content features?

These are out of scope for the pilot D8 and are follow-on questions.

## Why This Framing

The strongest defense of the work is that the platform is useful regardless of D8's outcome. If H1 is true, the platform is a validated research instrument. If H1 is false, the platform is a documented open-source failure mode — also a contribution, since pre-registered negative results are publishable when they are well-instrumented.

Either way, the Sleep Validation Toolkit, the architectural spec, and the open-source codebase remain useful. The platform ships; the empirical questions are separate.
