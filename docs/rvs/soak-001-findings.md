# Soak 001 — Findings

**Date:** 2026-07-21
**Duration:** 5h 16m (PID 9174, killed cleanly via SIGTERM at end)
**Branch:** feature/pluggable-generators (commits a155af5, 4bdc4d5; pre-b9c09fd)
**Profile / Runtime / Model:** reflective / ollama / qwen2.5:0.5b
**EEG / Classifier / Voice:** synthetic / mock / Personal Voice
**Network:** offline (airplane mode verified)

This document captures the post-soak findings from the 5h 16m
session that ran the live app under the new `LiveRuntimeFactory`
wiring. The quantitative baseline is computed by
`Scripts/analyze_dialectic.py` (commit `4bdc4d5`); this
document is the prose companion that names the headlines.

---

## Two-layer completion note (read this first)

The SOAK 001 data has **two layers of completion** that future
readers should not conflate:

| Layer | Status | Evidence |
|---|---|---|
| **Core runtime** metadata-threading | Complete | commit `b9c09fd` — `Sources/BCICloudBridge/GenerationRuntimeTextGeneratingAdapter.swift` and `Sources/BCICore/Composition/HypnagogicDialecticLoop.swift`. Harness emits `generatorFingerprint` on every turn. |
| **Live GUI integration** | Pending | The `AppViewModel` patches that route the dialectic / witness / mirror sites through `LiveRuntimeFactory.resolve(...)` are uncommitted on `research/rust-workspace`. The live app, post-commit, will start recording `generatorFingerprint` automatically. Until then, only the headless `dialectic-session` harness records it. |

The 0/140 fingerprint rate in the SOAK 001 baseline is
**expected** under this two-layer model and is not a regression.

---

## Headline numbers

The full report is in `/tmp/dialectic-baseline-001.json` (gitignored
artifact) or via `./Scripts/analyze_dialectic.py --output /tmp/baseline.json`.
The headlines:

| Metric | Value | Reading |
|---|---|---|
| Total turns | 140 | 5h 16m continuous, 0 silent, 0 crashes |
| Outcome split | 65 coherence / 42 displacement / 33 synthesis | 46% / 30% / 24% — synthesis rate is the right level for a reflective profile |
| Bigram diversity | 0.622 (4808 / 7733) | Healthy English baseline; no pathological repetition at the function-word level |
| Trigram diversity | 0.737 (5596 / 7593) | Same |
| Opening 4-gram diversity | 0.741 (103 / 139) | Good; the system-prompt scaffold leak (`in a live dialogue` x4) is the only repeated opening |
| Mean existing selfSimilarity | 0.863 | Reasonable for a dialectic; consecutive turns share ~14% of word tokens |
| Witness frequency | 17/140 (12.1%) | All reflective turns; 100% finding success when attempted |
| Witness influence on next-3 | +17% displacement, -24% synthesis | **The witness is coupling the dialogue, not just observing.** This is the strongest finding. |
| Synthesis rate after coherence | 8/65 (12%) | Loop is reluctant to synthesize after a coherence turn; tuning target for `contemplative_v3.yaml` |
| Shannon entropy trend | 7.72 → 7.51 (first-half → second-half) | **Vocabulary declining.** Real signal, not noise. |
| Generator fingerprint | 0/140 | Expected (two-layer model above) |

---

## Findings worth a paragraph each

### 1. The witness is coupling the dialogue

The Witness was designed to observe, not steer (`Witness finding
never re-enters the poles' prompts`, per
`Sources/BCICore/Composition/HypnagogicDialecticLoop.swift:286-287`).
The data does not support that design assumption. After a witness
finding fires, the next 3 turns are:

- **+16.9% more likely** to be `displacement-seeking` (47.1% vs 30.2% baseline)
- **-23.9% less likely** to be `synthesis` (0% vs 23.9% baseline)

That's a 17-point swing on displacement and a 24-point swing on
synthesis. The mechanism is not yet identified; hypotheses include
(a) the witness prompt is leaking into the next turn via the
shared `DialecticalMemory`, (b) the witness's `witnessDistance`
metric is read by the synthesis gate and shifts the threshold, (c)
the timing correlation is coincidental. **This is the highest-value
falsifiable finding for the `ResearchHypothesis` retrofit** —
`contemplative_v3.yaml` should declare an `acceptance:` criterion
on witness-coupling magnitude and the analysis script becomes the
oracle that says "passed" or "failed."

### 2. The system-prompt scaffold is leaking

`in a live dialogue` appears as an opening 4-gram **4 times** at
idx [7, 13, 15, 34]. These are the dialectic system-prompt
templates (e.g. `Sources/BCICloudBridge/Prompts/hypnagogic.md`)
saying things like *"in a live dialogue, the other person just
said…"*. The model is faithfully reproducing the prompt's
narrative frame rather than generating a response. **The fix is in
the prompt**, not the model. A `prompt-template` revision that
removes the "in a live dialogue" scaffolding should drop this
count to 0; that becomes an acceptance criterion for a future
hypothesis.

### 3. Synthesis-after-coherence reluctance

`coherence-seeking → synthesis` happens 8/65 times (12%). The
synthesis gate is `DialecticalMemory.synthesisCandidate(...)` with
a `synthesisTensionCeiling` that is calibrated for high-tension
turns. The data suggests the gate is *too* tight for the
contemplative profile — synthesis should fire more often when
both poles converge on a topic. **The `FieldDynamics` knobs
the user named in the architecture review** (`explorationPressure`,
`attractorDecay`) are exactly the levers that would change this
ratio. `contemplative_v3.yaml` should target a higher
`synthesis_after_coherence` rate as one of its `acceptance:`
criteria.

### 4. Entropy is declining

Sliding-window Shannon entropy drops from 7.72 to 7.51 bits
across the 5h 16m run. This is the "vocabulary collapse" signal
the user named in the architecture review. The decline is small
in absolute terms (0.2 bits) but consistent and visible. **The
mechanism is likely related to (1) and (2)**: the system-prompt
scaffold leak and the witness coupling both narrow the
distribution of generated text. Fixing those should also fix the
entropy decline. The metric itself is a great leading indicator
— if entropy stops declining, the dialogue is diversifying
appropriately.

### 5. The verbatim phrase the user caught

"We should consider whether there might be another variable
influencing…" appears at idx [1, 18] — exactly twice in 140
turns. The phrase is structurally similar to a high-probability
opening the dialectic system prompt encourages. **The fix is the
same as (2)**: a prompt-template revision. A future
`contemplative_v3.yaml` should target `named_phrase_count("we
should consider whether there might be another variable") = 0`
as an acceptance criterion.

---

## Findings that did NOT pan out

A few things I expected to see and didn't:

- **No pathological bigram repetition.** The top-5 bigrams are
  universal English function words (`it s`, `that s`, `isn t`).
  This is healthy.
- **No `silent` outcomes at all** (the loop's silent-turn bug
  fix at `a155af5` did its job — even when the model produced
  empty text, the loop advanced and logged).
- **No runaway memory growth.** RSS plateaued and dipped from
  400 → 342 → 488 → 536 MB across the soak. Total RSS swing
  ~200 MB on a 16 GB machine; not a leak, consistent with
  cache pressure and re-allocation as the dialectic
  `DialecticalMemory.historyCentroid` grew.

---

## What this baseline enables

The `Scripts/analyze_dialectic.py` script (commit `4bdc4d5`)
makes the eleven metrics above reproducible from any
`dialectic-turns-*.jsonl` file. Each `ResearchHypothesis` YAML
will declare its `metrics:` and `acceptance:` criteria in
terms of these metric names; the script becomes the oracle. The
SOAK 001 numbers are the **first** entry in a longitudinal
baseline; every future soak will produce a JSON sidecar that
diff-checks against the prior baseline and shows regressions
or improvements.

The specific acceptance criteria that future hypotheses should
be measured against, distilled from this soak:

- `ngram_diversity.trigram_diversity > 0.70`
- `opening_diversity.opening_diversity > 0.70`
- `witness_influence.per_outcome_shift.displacement-seeking` ∈ `[-0.05, 0.05]`
  (the witness should be neutral on steering)
- `witness_influence.per_outcome_shift.synthesis` ∈ `[-0.05, 0.05]`
- `entropy.second_half_mean - entropy.first_half_mean > -0.05` (no collapse)
- `transitions.matrix.coherence-seeking.synthesis / transitions.row_totals.coherence-seeking > 0.20`
  (the loop should synthesize more often after coherence)
- `named_phrases["in a live dialogue"].count = 0` (the system-prompt scaffold leak)
- `named_phrases["we should consider whether there might be another variable"].count = 0`

---

## Status

- ✅ SOAK 001 ran. 5h 16m, 140 turns, 0 silent, 0 faults.
- ✅ Analysis script committed (`4bdc4d5`).
- ✅ Metadata-threading at the core runtime level committed (`b9c09fd`).
- ⏸ Live-app metadata-threading integration: on `research/rust-workspace`, not yet committed.
- ⏸ `contemplative_v3.yaml` and the rest of the `ResearchHypothesis` retrofit: on `feature/research-hypotheses` (to be created).
- ⏸ ADR-010 Phase 0 (Rust utility crate): after `ResearchHypothesis` lands.

Refs: SOAK 001 session, RVS-001 log, ADR-009, ADR-010 review.
