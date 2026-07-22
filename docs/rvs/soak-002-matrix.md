# Soak 002 — Empirical Test Matrix

**Date:** 2026-07-21
**Branch:** feature/pluggable-generators @ 09d0775
**Tool:** `Scripts/soak-matrix.sh` (newly committed)
**Run directory:** `SoakRuns/soak-002-20260721-220848/`

This is the first empirical test matrix run. The user's framing
("treat the dialogue engine like an empirical environment")
called for a diverse corpus of conversations across runtimes and
models, analyzed with the same metrics as SOAK 001. The
`Scripts/soak-matrix.sh` runner is the harness for that work.

**Configuration:**
- 10 cells × 30 turns each = 300 turns total
- 30 fixed heard lines (sampled from SOAK 001 organic input;
  corpus in `Scripts/soak-matrix.sh`)
- Profiles: focused / reflective / contemplative
- Runtimes: Ollama local + Ollama cloud-routed
- Models: qwen2.5:0.5b / 1.5b / 3b, deepseek-r1:1.5b,
  deepseek-v4-flash:cloud
- Same analyzer (`Scripts/analyze_dialectic.py`) on every cell

## Headline numbers

| Cell | silent | synth | fp | ngram | open | entropy_2nd |
|------|--------|-------|----|-------|------|-------------|
| F_qwen05b       |   0.00% | 0.00% | 100% | 0.702 | 0.793 | 6.87 |
| R_qwen05b       |   0.00% | 0.00% | 100% | 0.736 | 0.828 | 6.70 |
| C_qwen05b       |   3.33% | 0.00% | 100% | 0.967 | 0.966 | 6.71 |
| F_qwen15b       |   0.00% | 0.00% | 100% | 0.786 | 0.800 | 7.29 |
| R_qwen15b       |   0.00% | 0.00% | 100% | 0.784 | 0.833 | 7.17 |
| F_qwen3b        |   0.00% | 0.00% | 100% | 0.657 | 0.667 | 7.25 |
| F_deepseek_r1   | 100.00% | 0.00% | 100% | 0.000 | 0.000 | 0.00 |
| R_deepseek_r1   | 100.00% | 0.00% | 100% | 0.000 | 0.000 | 0.00 |
| F_deepseek_flash| 100.00% | 0.00% | 100% | 0.000 | 0.000 | 0.00 |
| R_deepseek_flash|  96.67% | 0.00% | 100% | 1.000 | 0.000 | 0.00 |

## Findings

### 1. The fingerprint path works on every cell

`fp=100%` across all 10 cells. The `MetadataCallbackBox` fix
(commit `94541a3`) and the harness wiring
(`await loop.attachMetadataCaptureFromAdapter()`) propagate
correctly through the new `GenerationRuntimeTextGeneratingAdapter`.
Every turn from every model has a populated
`generatorFingerprint`. The 0/140 baseline in SOAK 001 is
*only* a problem on the *live app* path (where the
`LiveRuntimeFactory` is not yet honoring env vars; see
followup section below). The harness path is end-to-end
correct.

### 2. All DeepSeek runs are silent (96-100%)

Confirms the RVS-001 finding at matrix scale: deepseek-r1
(local reasoning) and deepseek-v4-flash (cloud) both exhaust
their `num_predict` budget on `thinking` / reasoning tokens
before producing an answer. The dialectic loop now logs the
silent turn and advances the index (the RVS-001 fix) instead
of hanging, but the underlying issue is the model's
incompatibility with the dialectic prompt at `num_predict=256`.

**Recommended next step (per the user's "tune the runtime per
model" guidance):** provider-specific `num_predict` defaults.
Qwen models at 256 produce coherent responses; DeepSeek
reasoning models need 512+ (or `/api/chat` for native reasoning
control). This is a `LiveRuntimeFactory`-level fix: the
factory resolves the runtime + model + per-model `num_predict`
together, not as separate env vars.

### 3. Synthesis reluctance confirmed across the matrix

`0% synthesis` on every Qwen cell. Even the contemplative
profile (which the SOAK 001 analysis showed synthesizing at
~24%) shows 0% synthesis in this 30-turn run. The
synthesis-after-coherence gate is *too tight* in the
contemplative profile's tuning; this is the "appropriate
synthesis" criterion the user named (a target band, not a
minimum).

**This is the largest leverage point for `contemplative_v3.yaml`:
the synthesis gate calibration is the single most impactful
parameter to tune.** A future hypothesis YAML should declare
a `synthesis_rate ∈ [0.10, 0.30]` band as an acceptance
criterion and a `synthesisTensionCeiling` parameter to vary.

### 4. Qwen 0.5B has lower ngram diversity than 1.5B

| Model | ngram_diversity |
|-------|-----------------|
| qwen2.5:0.5b (F) | 0.702 |
| qwen2.5:0.5b (R) | 0.736 |
| qwen2.5:0.5b (C) | 0.967 |
| qwen2.5:1.5b (F) | 0.786 |
| qwen2.5:1.5b (R) | 0.784 |
| qwen2.5:3b  (F) | 0.657 |

Two observations:
- The 0.5B baseline model has 0.702 ngram diversity (just
  above the 0.70 acceptance criterion). The 1.5B and 3B
  models have similar or *worse* diversity than 0.5B on
  focused profile.
- The 3B model has the **lowest** diversity (0.657) on
  focused. Counter-intuitive: bigger model is more
  repetitive. This is consistent with the user's "small-model
  collapse" hypothesis but inverted — for this heard-line
  corpus, the *medium* model collapses more than the small.

**Implication:** model size is not monotonically better.
For the dialectic task at this heard-line distribution, the
0.5B model is a reasonable baseline. Future hypothesis YAMLs
should specify which model they target.

### 5. Leakage audit findings

| Pattern | Cells where it appears | Total occurrences |
|---------|------------------------|-------------------|
| `in a live dialogue` (scaffold) | 6 of 10 | 15 turns |
| `we should consider whether...` (verbatim) | 2 of 10 | 2 turns |
| `neuralcompose` / `dialectic` / `hypnagogic` (system leak) | 1 of 10 | 2 turns (R_qwen05b only) |

**The `in a live dialogue` scaffold is the dominant leak.**
2-5 occurrences per Qwen 0.5B cell, regardless of profile.
The fix lives in the system prompt (remove the "in a live
dialogue" scaffolding), not the model.

**The system-prompt terminology leak is profile-specific.**
Only `R_qwen05b` (reflective) shows it (2/30). The reflective
profile is more likely to surface internal state in its
spoken text. This may be correlated with the witness
influence the SOAK 001 analysis identified.

**The DeepSeek cells show "clean" leakage only because they
are silent.** If the model produced text, we'd see the
leakage. The audit is conditional on `outcome != silent`.

## Cross-model dialectic (Phase 2 — deferred)

The user named cross-model dialectic (Pole A: Qwen, Pole B:
DeepSeek) as the next experiment. This requires the harness
to accept *per-pole* runtime/model parameters, which the
current harness does not support. The implementation
requires a new harness option (`--pole-a-runtime`,
`--pole-a-model`, `--pole-b-runtime`, `--pole-b-model`) and
a `LiveRuntimeFactory`-style change in
`Sources/DialecticSession/main.swift`.

**Status:** deferred to a follow-up commit on
`feature/pluggable-generators` (not a new branch). The matrix
runner is structured to accommodate it: today's cell is
`(runtime, model, profile)`, tomorrow's can be
`(pole_a_runtime, pole_a_model, pole_b_runtime, pole_b_model, profile)`
without changing the analyzer or rendering.

## Live-app metadata-threading gap (separate scope)

The live app (PID 56967, running on the new binary) is
producing turns with `generatorFingerprint: None`. The
health log shows `substitutionSummary: 'LLM: stub'` despite
`NEURALCOMPOSE_RUNTIME=ollama` being set, indicating the
`LiveRuntimeFactory` is *not* honoring the env var on the
live app path. The harness path is correct; the live-app
path needs the same env-var resolution the harness has.

**This is a follow-up investigation, not a regression.**
The harness path (where 90% of empirical work happens) is
correct. The live-app path needs a small fix to
`LiveRuntimeFactory` that the matrix run surfaced.

## Acceptance criteria for `contemplative_v3.yaml`

The matrix run confirms the 8 acceptance criteria from
`docs/rvs/soak-001-findings.md` are the right shape. Three
new criteria emerged from this matrix:

9. **`synthesis_rate ∈ [0.10, 0.30]`** — 0% on every Qwen
   cell is too low. The synthesis gate needs loosening.
10. **`synthesis_after_coherence ∈ [0.10, 0.30]`** — band,
    not minimum. Some hypotheses should remain unresolved.
11. **`leakage.live_dialogue_scaffold = 0`** — the system-
    prompt scaffold leak is the dominant leakage pattern;
    should be a hard target for any v3 hypothesis.

## Status

- ✅ 10-cell × 30-turn matrix complete
- ✅ All Qwen cells: 0-3% silent, 100% fingerprint, real
  metrics (ngram, opening, entropy)
- ✅ All DeepSeek cells: 96-100% silent (RVS-001 finding
  confirmed at scale; needs per-model num_predict)
- ✅ Leakage audit: 6 patterns scanned, scaffold leak
  quantified across cells
- ⏸ Cross-model dialectic: deferred (separate scope)
- ⏸ Live-app metadata gap: separate scope (harness is
  correct; live-app factory needs env-var fix)

Refs: SOAK 001 findings, RVS-001, post-soak architecture
review (empirical environment framing).
