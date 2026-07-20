# Dialectical Field v2 — `fieldEnergy` as an order parameter

**Status: specification only. Not implemented.** This document is an architectural contract for a
future capability. No code, dormant API, or TODO accompanies it. Implementation is deliberately
deferred until the shipped v1 engine has accumulated real interaction experience (see
[Roadmap](#10-roadmap)).

> The dialectical engine models conversation as a slowly evolving semantic field. Observable
> quantities — semantic drift, embedding geometry, dialogue history, and an optional `SpectralGloss`
> bias — update an internal field state that governs future competition. Context profiles *initialize*
> that field; interaction styles determine *how* competing interpretations are generated. The system
> adapts through the dynamics of the dialogue itself, never by inferring latent mental states from EEG.

## Why now, and why not yet

The v1 engine ([`README.md`](README.md), [`MATH.md`](MATH.md)) has stabilized: competition,
trajectory, semantic graph, silence, synthesis, two clocks, and the single `HypnagogicMode`
(mirror + the dialectic profiles). Those are **observable dynamics** — each is measured or resolved from a single turn.

`fieldEnergy` is different in kind: it is a **latent state variable**. Once it exists it touches nearly
every subsystem — competition, `τ(T)`, the silence and synthesis thresholds, tuning, telemetry, and
the profiles. That is a large commitment. Before making it, the current engine should answer questions
that only real use can answer:

- Does silence occur naturally, or never / always?
- Does synthesis fire too frequently?
- Does semantic drift run away?
- Does *Reflective* actually feel different from *Focused*?

Writing the specification now captures the design rationale while the architecture is fresh, and lets
the document act as a contract — without adding a latent variable we have not yet needed.

## 1. Observables vs. field state

Everything the field consumes today is an **observable**, measured each turn: `SpectralGloss` (fast),
and `entropy` / `drift` / centroids / `tension` (slow, from `DialecticalMemory`). v2 introduces a
second class — an **order parameter** that is not measured but *summarizes the evolving dynamics*:

```
FieldState { energy: Float }        // phase is a later, unspecified extension — see §9
```

`energy` evolves slowly and becomes part of the field's identity, alongside the existing
`DialecticalField.weights`.

## 2. What `fieldEnergy` is

**The dialogue's capacity to continue transforming itself** — a property of the *interaction*, not of
the user. It is derived entirely from semantic quantities the engine already computes. The Muse never
defines it.

## 3. Non-goals

Field energy is **not**, and must never be presented as:

- EEG / signal energy
- neural activation
- cognitive load
- emotional intensity
- sleep depth
- meditation depth
- attention
- arousal

It is purely an internal dynamical variable describing the dialogue itself. This boundary becomes more
important, not less, as the project grows — the value of the whole system rests on being honest about
what the hardware can and cannot support.

## 4. Energy dynamics — approximately conserved *(Stage A)*

Energy is not reinvented each turn; it flows through the loop's existing events. Reference update, with
every term mapped to a quantity that exists in v1 (`E ∈ [0, 1]`, clamped):

| Event | Contribution | Existing anchor |
|---|---|---|
| speech (novel candidates) | `+ κ_novelty · meanNovelty` | `DialecticalEnergy.novelty` |
| unresolved contradiction | `+ κ_tension · tension · [outcome ≠ synthesized]` | `DialecticalDynamics.tension` |
| new semantic region | `+ κ_region · (1 − maxSim(heard, graph))` | `SemanticGraph.nearestPriorNodes` |
| unexpected recurrence | `+ κ_recur · recurrenceSurprise` | a resurfaced node: far in time, near in space |
| successful synthesis | `− δ_synth · [outcome = synthesized]` | `.synthesized` outcome |
| repetition / collapse | `− δ_repeat · (1 − meanNovelty)` | `DialecticalEnergy.novelty` |
| baseline decay | `E ← (1 − λ_decay)·E` | — |
| silence | `E ← ρ·E`, `ρ ≈ 0.98` (minimal decay) | `.silent` outcome |

Energy therefore gives the field a *memory of its own activity*, distinct from the trajectory memory in
`DialecticalMemory`: resolution and repetition spend it, novelty and unresolved tension replenish it,
and silence costs almost nothing.

## 5. How energy acts — never through the scoring equation

The candidate potential `D(x) = ⟨λ, energy(x)⟩` stays exactly as it is in v1. Energy acts **only**
through the field and the dynamics knobs the engine already exposes (`DialecticalDynamics.Tuning`):

| Energy | Effect | Channel |
|---|---|---|
| high | sharper competition, faster divergence | lower `τ_base`; `+` novelty in `DialecticalField.target()` |
| low | softer, slower, quieter | higher `τ`; more readily silent; higher synthesis bars (wait to resolve) |

Concretely, energy becomes a new argument to `DialecticalField.target()` and a multiplier on `τ(T)`
and the silence / synthesis thresholds — never a term added to a candidate's potential. This is the
same discipline that kept *tension* out of the softmax: a field-level modulator, not a reward.

## 6. Profiles are initial conditions, not algorithm switches

This is the load-bearing frame. *Focused*, *Reflective*, and *Contemplative* are different **starting
points in one dynamical system**, not different algorithms. To make that literal, formalize the
behavioral space as a continuous preset:

```
FieldPreset { coherence, exploration, silenceTolerance, synthesisThreshold, initialEnergy }
```

`ContextProfile` ([`ContextProfile.swift`](ContextProfile.swift)) stays the public, honestly-named API
and gains `var preset: FieldPreset` plus a documented mapping of these five normalized dimensions onto
the concrete `Tuning` knobs and the initial `FieldState.energy`. The named profiles are simply points:

| Profile | coherence | exploration | silenceTol | synthThresh | initialEnergy |
|---|---|---|---|---|---|
| Focused | 0.9 | 0.2 | 0.1 | 0.3 | 0.30 |
| Reflective | 0.5 | 0.5 | 0.4 | 0.5 | 0.50 |
| Contemplative | 0.6 | 0.3 | 0.9 | 0.8 | 0.25 |

*Reflective* ≡ today's defaults at medium energy. *Contemplative* is low energy + high silence
tolerance + high synthesis threshold — it *spends more time waiting than speaking*, which is
non-elaboration, not "Dreamer++". New experiments (creative / analytic / therapeutic / educational)
become new points in the same space, with no change to the engine.

## 7. Silence as a dynamical state

`no dominant attractor → silence → minimal decay → competition resumes.` The metastable `.silent`
outcome already exists in v1; v2 simply stops treating it as a dead end and lets it persist cheaply.
It is the natural home of a contemplative profile — the field spends time in a low-energy, quiet regime
rather than being forced to respond.

## 8. Two clocks preserved

`SpectralGloss` remains the **fast** clock with small modulation; the field — now `weights + energy` —
is the **slow** identity. Energy evolves slowly. The EEG *influences* the field through the existing
gloss term but never *defines* energy.

## 9. Phase — a later, unspecified extension *(Stage B)*

Energy alone is enough to evaluate first. A second order parameter, `phase` — roughly, where the
dialogue sits in a divergence↔convergence cycle — is **named but deliberately left unspecified** here.
Specifying its mathematics now would mean optimizing for something we have never observed. It is
defined only after Stage A has been lived with.

## 10. Roadmap

```
v1  implemented   competition · graph memory · silence · synthesis · two clocks · profiles
v2  documented    FIELD_V2.md — energy · (phase) · continuous profiles / behavioral space
future            Stage A  energy               → collect observations
                  Stage B  phase                → collect observations
                  Stage C  attractor adaptation
```

Each future stage is independently testable and revertible. Stage A must keep `Reflective` behaving
exactly like the current defaults. When Stage A is built, these are the anchors it will touch — recorded
here as *intent*, not code: `DialecticalField.advance` / `target`, the `HypnagogicDialecticLoop` turn
step that resolves the outcome, `DialecticalDynamics.Tuning` (new coupling coefficients), and
`DialecticalTurnEvent` (record `energy`). Its acceptance criteria: energy decays without input;
synthesis dissipates it; a silent turn barely changes it; sustained high energy yields more divergence
(lower `τ`); profile `initialEnergy` ordering holds; and `ContextProfile.reflective` still equals
today's behavior.

## 11. Research framing

Names describe *interaction style*, never a detected or induced cognitive or meditative state. If
traditions such as zazen are cited, they are **inspiration for the interaction design** — not something
the system recognizes, verifies, or guides. Energy is a property of the dialogue's dynamics; no
EEG-derived mental-state claim is made anywhere in this design.

## 12. Open questions (resolved at implementation time)

- Coupling coefficients (`κ_*`, `δ_*`, `λ_decay`, `ρ`) — empirical, tuned against observed behavior.
- Energy bounds and how strictly conservation should hold.
- Whether energy eventually *replaces* the current fixed silence/synthesis thresholds or only
  *modulates* them.
- Whether `phase` is discrete (expansive / convergent / quiescent) or continuous — deferred to Stage B.
