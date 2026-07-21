# Dialectical Hypnagogic Mode — Mathematics

Notation for the mechanics implemented in `DialecticalDynamics`,
`DialecticalField`, and `SpectralGloss`. All similarities are cosine on
L2-normalized `Embedding` values, so `cos(a, b)` is a plain dot product in
`[-1, 1]`. Default parameter values are the shipped `Tuning` defaults.

## 1. Normalized similarity

Everything is rescaled to a common non-negative axis:

```
n(a, b) = ( cos(a, b) + 1 ) / 2            ∈ [0, 1]
```

## 2. Energies

For a candidate `x` against the turn context (`h` = heard, `Hc` = history
centroid of past heard utterances, `Rc` = reply centroid of past replies):

```
coherence C(x) = n(x, h)                        fidelity to what was heard
resonance R(x) = n(x, Hc)     (0.5 if Hc = ∅)   fit to the accumulated trajectory
novelty   N(x) = 1 − n(x, Rc) (0.5 if Rc = ∅)   departure from what we've said
```

Missing centroids (early turns) score the neutral `0.5`, biasing neither pole.

## 3. Dialectical potential

The weighted score the competition samples over:

```
D(x) = λc·C(x) + λr·R(x) + λn·N(x) = ⟨λ, energy(x)⟩
```

with `λ` supplied by the field (§8). Base weights `λ = (λc, λr, λn) =
(1.0, 0.6, 0.8)`.

## 4. Tension

Mean pairwise dissimilarity of the candidate embeddings:

```
T = mean over pairs (i<j) of ( 1 − n(xᵢ, xⱼ) )     ∈ [0, 1]     (0 if <2 candidates)
```

**Tension is not a scoring term.** A term `λt·T` is identical for every
candidate, so it cancels in the softmax ratio `P(xᵢ)/P(xⱼ)`. `T` therefore acts
only on the *dynamics*: the selection temperature (§6), the prosody blend, the
synthesis gate (§7), and the prompt shapers.

## 5. Selection temperature

```
τ(T) = max( τmin , τbase − τslope · T )
     = max( 0.12 , 0.5 − 0.35 · T )
```

Higher tension ⇒ lower τ ⇒ a sharper competition — which is also more *volatile*
near equilibrium, since a small margin under a low τ flips on the smallest
perturbation. The floor `τmin` keeps the bifurcation alive.

## 6. Resolution

Let `D₍₁₎ ≥ D₍₂₎ ≥ …` be the sorted potentials and `margin = D₍₁₎ − D₍₂₎`.

**Silence (metastability).** With ≥2 candidates:

```
if margin < stalemateMargin (0.05)  and  T ≥ highTension (0.6):   → silent
```

An opposed, undecided turn holds its tension and says nothing; the tension
persists into the next turn. (A *low*-tension near-tie is near-agreement, and
still speaks.)

**Symmetry breaking.** Otherwise sample a basin from the softmax:

```
P(xᵢ) = exp( (D(xᵢ) − maxⱼ D(xⱼ)) / τ )  /  Σₖ exp( (D(xₖ) − maxⱼ D(xⱼ)) / τ )
idx   = min { i : draw < Σₖ₌₁ⁱ P(xₖ) },     draw ~ injected uniform in [0,1)
```

`draw` is the single point of non-determinism (injected, so tests are
deterministic). A `margin ≥ decisiveGap (0.25)` is flagged *decisive*: the
dynamics, not the draw, chose.

## 7. Synthesis

Reconciliation strength of a candidate `c` relative to the two poles — its
similarity to whichever pole it is *farther* from:

```
S(c) = min( n(c, thesis) , n(c, antithesis) )     ∈ [0, 1]
```

> Geometry note. "Far from both poles yet explaining both" is contradictory in a
> metric space (the point nearest their midpoint is still ~45° from each). So `S`
> measures *reconciliation* — closeness to both at once. A copy of one pole
> scores only the poles' own cross-similarity `n(thesis, antithesis)`. The
> synthesis's "transcendence" comes not from distance but from it being a
> **recurring idea resurfaced from the semantic graph**.

Gate. Let the convergence streak `k` count consecutive turns with
`T ≤ tensionCeiling (0.35)`. A resurfaced graph node (the highest-`S` neighbour
of the poles' midpoint) becomes the synthesis when

```
S ≥ bar,     bar = (k ≥ K)  ?  synthesisLowBar (0.45)  :  synthesisHighBar (0.6),   K = 4
```

i.e. a strict bar while the poles are opposed, a gentler bar once the dialogue
has been converging.

## 8. The weight field (slow clock)

The weights evolve with inertia rather than being recomputed each turn:

```
λₜ = (1 − η)·λₜ₋₁ + η·target(λ_base, glossₜ, entropy, drift),     η = fieldInertia (0.12)
```

The target (the tunable policy; `wind = 0.35`, `lean = 2·(gloss − 0.5) ∈ [-1,1]`):

```
novelty*   = λ_base.n + wind·lean − 0.5·wind·entropy − 0.5·wind·drift
coherence* = λ_base.c − 0.5·wind·lean
resonance* = λ_base.r − 0.5·wind·lean
target     = ( max(0, coherence*), max(0, resonance*), max(0, novelty*) )
```

Relaxed gloss (`lean → +1`) gently favours novelty; engaged (`lean → −1`) favours
coherence/resonance; a wandering dialogue (high `entropy`/`drift`) reins novelty
back in. All shifts are small, and inertia `η` spreads them over many turns.

Interaction-history quantities (slow clock), from the recent reply embeddings
`r₁ … rₘ`:

```
entropy = mean over pairs (1 − n(rᵢ, rⱼ))              spread of recent replies
drift   = mean over consecutive (1 − n(rᵢ, rᵢ₋₁))      how fast the position moves
```

## 9. The gloss (fast clock)

An EMA over the instantaneous `SpectralState → scalar` map:

```
glossₜ = glossₜ₋₁ + α·( s(stateₜ) − glossₜ₋₁ ),        α = glossEMAAlpha (0.6)

s(drowsy)=1.0   s(relaxed)=0.8   s(neutral | none)=0.5   s(engaged)=0.2   s(highLoad)=0.1
```

## 10. Two-clock separation

The gloss (fast `α = 0.6`) tracks the EEG window-to-window; the field (slow
`η = 0.12`) absorbs it. A single one-window gloss spike moves the weights by at
most `η · wind` before it decays, so no single noisy window can rewrite the
dialogue's semantic identity. The two clocks meet only inside `target` (§8).

## 11. Centroid

```
centroid(e₁ … eₙ) = normalize( (1/n) Σ eᵢ )      (∅ → undefined)
```

Provenance (`modelID` / `version` / `dimension`) is inherited from the first
element.
