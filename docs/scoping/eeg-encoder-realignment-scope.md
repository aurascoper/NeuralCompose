# Scope — EEGEncoder re-alignment (the "gloss only ever says High load" thread)

Status: scoping. Opened 2026-07-21 after the demean fix (#21) unstuck the gloss
mechanically but exposed the real bottleneck.

## The problem, precisely

With the artifact-gate demean landed, the estimator now emits states and the
gloss reaches the dialectic (`glossScalar 0.5 → 0.26` observed live). But every
non-null state this session was `"High load"` (7/7). The encoder does not
discriminate the five spectral/cognitive states — it collapses to one.

Root metric: `Models/EEGEncoder/metadata.json` `mean_cos_to_target = 0.262`.
The encoder→text-space alignment is marginal, so the argmax over the 5 anchor
descriptors is near-degenerate. This is a **model-quality** problem, not a
signal or gate problem — no amount of electrode/gate work moves it.

## What "done" would mean (pre-register BEFORE training)

Per Track-B discipline (pin the metric first; held-out only; a null is a valid,
publishable outcome):

- **Primary held-out metric:** 5-way state discrimination on a leak-controlled
  held-out set — e.g. balanced accuracy over {drowsy, relaxed, engaged, high-load,
  neutral}, or per-state mean cosine-to-correct-anchor minus mean
  cosine-to-others (a separation margin). Pin a defensible bar (e.g. balanced
  acc ≥ 2× chance = 40%, or a strictly-positive separation margin with CI) BEFORE
  training. No promotion on training loss or `mean_cos_to_target` alone.
- **Provenance/honesty gate stays:** the estimator already refuses a mismatched
  anchor space (`target_space` must start with `bge:` AND the live embedder must
  be real BGE). Keep it; do not relax to make numbers move.

## The hard dependency (this is why it may park, like Track B)

The encoder trains on `(window → descriptor)` pairs labelled by
`eeg_spectral.py::descriptor_for_ratios` (Welch band ratios → one of 5
descriptors). That labelling needs **real EEG with genuine band-structure
variation across the 5 states**. Current corpus:

- one processed night of sleep data (WorldModel spike) — dominated by a few
  states, not a balanced 5-way set;
- synthetic 1/f (WorldModel) — has a controllable exponent but is not the
  cognitive-state axis the descriptors encode;
- zero balanced, labelled waking-state EEG.

So the same data-volume wall that blocks the JEPA blocks this. **The `0.262`
may be near the ceiling for this montage + this corpus.** The scope must include
a go/no-go: if a retrained/re-anchored encoder cannot clear the pinned held-out
bar, the EEG-shaped-gloss ambition parks and the gloss stays an explicit
heuristic-bias-only signal (as `SpectralState.honestyCaveat` already frames it).

## Candidate work (in rough dependency order)

1. **Characterise the current encoder first (cheap, do before any training).**
   Dump the confusion over the 5 anchors on whatever labelled windows exist —
   confirm the "always High load" collapse and whether it is a data-imbalance
   artefact (labels are ~all one class) vs. a genuine encoder failure. This
   decides whether the problem is fixable at all with current data.
2. **Balance/augment the label set.** If labels are imbalanced, re-derive them
   over a wider band-ratio range; consider per-subject threshold calibration in
   `descriptor_for_ratios` (its thresholds are explicitly tunable defaults).
3. **Re-anchor without retraining (cheapest lever).** The runtime rebuilds
   anchors by encoding the descriptor phrases through live BGE. Test alternative
   descriptor phrasings that separate better in BGE space before touching the
   EEG encoder weights.
4. **Retrain the encoder** only if 1–3 show the ceiling is not already hit.
   Same 3-phase MLX recipe as the current model; measure against the pinned
   held-out bar, not training loss.

## Explicitly NOT in scope

- Signal/gate/electrode work (that thread closed with #21).
- Promoting on `mean_cos_to_target` or training loss.
- Relaxing the anchor-space honesty gate.
- Committing to a retrain before step 1 proves the current data can support
  5-way discrimination at all.

## Related threads

- WorldModel/JEPA — same "no labelled EEG volume" wall; both are contingent on a
  labelled-data story that does not exist yet.
- Track B (imagined speech) — the montage-ceiling precedent; the go/no-go
  discipline here mirrors its pre-registration gate.
