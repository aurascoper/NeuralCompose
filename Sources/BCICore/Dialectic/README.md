# Dialectical Hypnagogic Mode

*A non-deterministic semantic dynamical system for NeuralCompose.*

## What this is

NeuralCompose already contains nearly every component a genuinely dialectical
hypnagogic interaction needs. What was missing is not a new reasoning engine but
a different **execution model**. This module supplies that model, reusing the
existing embedding backend, text generator, speech synthesizer, telemetry, and
privacy surfaces.

Today contradiction is generated and then immediately resolved, in two places:

- `DialecticEngine` computes thesis → antithesis → synthesis but collapses them
  into one synthesized string.
- `HypnagogicDialogueLoop.run()` runs one generation pass and speaks the result.

Both behave as deterministic prompt → response pipelines. This module replaces
that with an **opt-in dialectical loop** in which semantic contradiction is
allowed to *persist across time*. The dialogue becomes a continuous dynamical
system whose **trajectory** — not any single response — is the object of
interest.

Track A (intent classification, carousel typing) is untouched. The dialectical
loop lives only inside the opt-in hypnagogic sandbox.

## The shift

| Communication mode (Track A) | Dialectical hypnagogic mode |
| --- | --- |
| "What does the user intend?" | "How does meaning evolve under competing interpretations?" |
| classify → decide → act | generate tension → let it compete → preserve it |
| a correct answer | an evolving semantic trajectory |
| contradiction is an error | contradiction is a state variable |

## Per-turn dynamics

```
heard (on-device STT)
      │
   for each DialecticalRole:  generate( promptShaper(heard, tensionₜ₋₁), role.temperature )
      │                        # tension shapes the prompt: push far vs. explore near
   embed heard + candidates   (SentenceEmbedder — MLX-free cosine geometry)
      │
   Dₓ = λc·coherence + λr·resonance + λn·novelty          # λ from the field (below)
   T  = mean pairwise (1 − cos) among candidates          # tension (symmetric)
      │
   memory.synthesisCandidate?  ── an old graph node that reconciles the two poles
      │
   compete(D, T, τ(T), draw):
        decisive gap ─▶ spoke(dominant basin)             # dynamics decide
        near equilibrium ─▶ spoke(sampled basin)          # a perturbation tips it
        high-T stalemate ─▶ SILENT (carry tension into t+1)
        reconciling third / sustained low tension ─▶ synthesized
      │
   speak(text, prosody = blend(role voices, weights = softmax D))   # tension is audible
      │
   memory.append(competition) ; graph.insert(nodes, similarity edges)
   field.advance(glossₜ, entropy, drift)   → λₜ₊₁         # slow semantic clock
   gloss.update(SpectralState)              → glossₜ₊₁    # fast biological clock
      ↺
```

## Competing generators — objectives, not identities

Each turn every `DialecticalRole` generates one candidate from its own
tension-aware prompt at its own sampling temperature. The first implementation
ships two:

- **coherence-seeking** — maximises semantic continuity (low temperature).
- **displacement-seeking** — maximises semantic displacement: metaphor,
  associative distance, symbolic recombination (high temperature).

They are optimisation objectives, not personalities, so which candidate turns
out to be "the stabilising move" *emerges* from the energies each turn. Adding a
counterfactual / emotional / analogical role later is data, not a redesign — the
competition already iterates over `[DialecticalRole]`.

## Tension is not a score

Tension `T = 1 − cos(thesis, antithesis)` is the same scalar for every
candidate, so as an additive term `λt·T` it cancels in the softmax ratio.
Instead it governs the *dynamics*: the selection temperature `τ(T)`, the prosody
spread, the synthesis gate, and — through `promptShaper` — the generators
themselves. Tension shapes the semantic landscape rather than acting as another
reward.

## Symmetry breaking

Selection is a single tension-sharpened softmax sample, not a coin flip. Far
from equilibrium the potential gap makes the outcome near-deterministic; near
equilibrium the injected draw tips the basin (a bifurcation). Two dialogues
beginning identically can therefore diverge after a few turns — dream-like
evolution without sacrificing coherence.

## SpectralState as wind, on its own clock

The Muse is never a cognitive decoder: `EEG → band features → SpectralState →
gloss scalar → interaction bias`, never `EEG → mental state → dialogue`. The
gloss runs on a **fast** EMA clock; the competition weights run on a **slow**
`DialecticalField` (a leaky integrator with inertia). The two combine *only*
inside the field's target, so a single noisy window cannot rewrite the
dialogue's semantic identity. The modulation is deliberately small — a wind, not
a steering wheel.

## Memory — a graph of transformations

The dialogue is remembered not as a transcript but as a `SemanticGraph`: nodes
are past utterances and replies, edges are embedding similarity. Old ideas can
reappear because they remain nearby in that space. `DialecticalMemory` wraps the
graph plus the history/reply centroids and the slow-clock quantities (`entropy`,
`drift`).

## Synthesis — an event, not the default

Synthesis is no longer a function call at the end of every turn. It fires only
when a resurfaced idea *reconciles* the two poles (is close to both) — under a
strict bar while the poles are opposed, and a gentler bar once tension has
stayed low for several turns. Most turns simply keep the contradiction alive.

## Silence — a first-class outcome

A high-tension near-perfect stalemate resolves to **silence**: nothing is said,
and the unresolved tension is carried into the next turn (metastability),
bounded so the loop never stalls permanently. Saying less is a legitimate move,
not a failure mode.

## File map

| File | Role |
| --- | --- |
| `DialecticalCompetition.swift` | value types: weights, energy, candidate, scored candidate, outcome, turn record |
| `DialecticalRole.swift` | a competitor as *objective + tension-aware prompt shaper + voice*; the two built-in roles |
| `DialecticalDynamics.swift` | the pure math: energy, tension, `τ(T)`, softmax sample, silence/synthesis resolution, centroid, synthesis score |
| `SemanticGraph.swift` | bounded graph of nodes + similarity edges; recurrence lookup |
| `DialecticalMemory.swift` | graph + centroids + entropy/drift + the two-tier synthesis gate |
| `DialecticalField.swift` | slow clock: the weights as a leaky integrator with inertia; the tunable `target` policy |
| `SpectralGloss.swift` | fast clock: EMA-smoothed `SpectralState` → bias scalar |
| `../Composition/HypnagogicDialecticLoop.swift` | the actor tying it together |
| `../Composition/HypnagogicRunnable.swift` | the lifecycle both hypnagogic loops share |
| `../Telemetry/DialecticalTurnEvent.swift` | opt-in per-turn record + logging seam |

The mathematics is written out in [`MATH.md`](MATH.md).

## Scientific boundaries

This mode is explicitly experimental. It makes **no** claim to detect
hypnagogia, classify consciousness, infer intention, or decode dreams. The Muse
provides only a modest, caveated spectral *gloss*. The semantic dynamics arise
from the interaction between language generation, embedding geometry, and
accumulated conversational history — not from EEG interpretation. It is
manual-trigger, opt-in, off by default, and NOT wired to any sleep-stage
detector.

## Privacy

The loop reuses the existing on-device STT + opt-in cloud generator path: only
transcript *text* (never audio) can leave the machine, and only while active and
disclosed in the privacy banner. Dialectical mode makes **two** generation calls
per turn (one per role). Turn records are persisted only when the interaction-log
opt-in is on, to a separate `dialectic-turns-<day>.jsonl` stream.
