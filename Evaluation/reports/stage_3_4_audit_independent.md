# Stage 3.4 Independent Audit

**Date:** 2026-07-14
**Reviewer:** Sonnet 5 ("Sonnet Agent 1 — Stage 3.4 Auditor" role)
**Repository:** ~/Developer/NeuralCompose
**Snapshot:** git HEAD `a65886d092c14e9105c030cfec1189c26c6939ed`, branch `feat/generation-eval-harness`, captured 2026-07-14T09:37:44Z

## Scope and method

This is an **independent** review, not a continuation of the existing self-audit at `Evaluation/reports/stage_3_4_audit.md` ("GLM-5.2 reviewer", committed in `d691e25`, followed by a remediation commit `d79af03 eval: fix Tier 1 scientific state issues`). This audit reads that prior document, checks whether its findings and fixes actually hold against current on-disk state, and extends coverage into areas it didn't touch: documentation synchronization, statistical-methodology code review, and decision-registry traceability.

Per its charter, this audit **inspects outputs only**. It does not modify benchmark code, does not modify anything under `Evaluation/results/` or `Evaluation/corpora/`, and does not rerun any benchmark. It does execute the existing read-only validator (`Evaluation/scripts/validate_checkpoints.py`), which reads and reports but writes no files under `Evaluation/`.

**A live benchmark process is running concurrently with this audit.** `ps` confirms PID 82243 (`embedding_streaming_benchmark.py --skip-existing --retry-failed`, started ~04:17 local) is actively adding embedding candidates and rewriting `Evaluation/results/embeddings/leaderboard.json` as this document is written. A prior instance (PID 66007, started 04:04) completed and exited before this audit began. Every finding below is anchored to a frozen snapshot of key JSON files copied at 2026-07-14T09:37Z (see file list in Appendix); numbers quoted are from that snapshot, not from re-polling live files, so the report is internally consistent even though the underlying leaderboard keeps moving. Findings driven by "still collecting data" (e.g., partial candidate coverage) are explicitly distinguished below from findings driven by "a distinct pipeline defect" (e.g., orphaned aggregate values, dead statistical code, stale prose).

## Naming note

The requested output filename `STAGE_3_4_AUDIT.md` was not used: this repository sits on an APFS volume, which is case-insensitive by default. `ls Evaluation/reports/STAGE_3_4_AUDIT.md` resolves to the *existing* `stage_3_4_audit.md` (same inode, 427 lines) — writing the requested name would have silently overwritten the prior audit. This document is `stage_3_4_audit_independent.md` instead, matching the directory's existing lowercase-snake_case convention.

---

## 1. Relationship to the prior audit

The prior audit (`stage_3_4_audit.md`) is thorough and its RQ1–RQ5 findings are corroborated below. Two things are worth flagging about its current state:

**Its headline fix does appear to have landed, but the document didn't update itself to say so.** The prior audit's body text (§"RQ1: Runtime Equivalence") and its own Summary Table both state hypothesis `3.4-A-runtime-consistency` is "marked evaluated (vacuous)" in the registry — a status error it recommends correcting. Reading the *current* `Evaluation/corpora/hypothesis_registry.json` directly:

```json
"id": "3.4-A-runtime-consistency",
"status": "blocked",
"status_note": "No multi-runtime data: Python embedding benchmark failed for -mlx variants
 (ignore_mismatched_sizes), MLX runtime failed (No module named 'mlx'). The script ran and
 produced a valid report with 0 comparisons. This hypothesis has NOT been tested."
```

The status is now `"blocked"` with an accurate note — not `"evaluated"`. Given the fix commit `d79af03 eval: fix Tier 1 scientific state issues` sits directly after the audit commit `d691e25` in `git log`, this strongly suggests the fix was applied in response to the audit. That's a healthy signal: the audit-fix loop worked. But `stage_3_4_audit.md` itself was never revised afterward, so a reader of that document today sees a false claim about the registry it's describing — the *audit is now stale documentation about its own subject*. This document's "Stale documentation" list (§7) includes this.

**RQ2–RQ4 findings are corroborated.** Spot-checking `Evaluation/results/stage_3_4/embedding_space_analysis.json`, `cross_model_agreement.json`, and `generator_comparison.json` against the prior audit's tables was not repeated in full here (out of scope for the delta this audit adds), but nothing in the artifact inventory contradicts the prior audit's N=10-sample caveats for RQ2/RQ3 or its "strong evidence" characterization of RQ4. No reason to dispute those.

---

## 2. Hypothesis registry validation

`Evaluation/corpora/hypothesis_registry.json` (v1) is well-formed: 6 Stage 3.4 hypotheses (3.4-A through 3.4-F) and 6 currently-defined Stage 3.5 hypotheses (3.5-A, B, C, D, E, P — the lettering is intentionally sparse, not a gap). Each entry has `metric`, `success_criterion`, `expected_effect_size`, `status`, and (where relevant) a `status_note`. This is good pre-registration hygiene — success criteria were written before evidence existed, which is what makes the "evaluated (supported)" statuses for 3.4-C/D/E meaningful rather than post-hoc.

Current statuses, cross-checked against artifacts in this snapshot:

| ID | Status in registry | Artifact exists? | Assessment |
|----|--------------------|--------------------|------------|
| 3.4-A | `blocked` | `cross_runtime_consistency.json` (0 comparisons) | Accurate — correctly reflects no data |
| 3.4-B | `pre-registered` | none | Accurate — correctly deferred |
| 3.4-C | `evaluated`, status_note flags N=10 pilot | `embedding_space_analysis.json` | Accurate — status_note discloses the limitation inline, which is good practice |
| 3.4-D | `evaluated`, status_note flags 2-model/N=10 pilot | `cross_model_agreement.json` | Accurate, same as above |
| 3.4-E | `evaluated`, status_note claims "strong evidence" | `generator_comparison.json` | Consistent with prior audit's characterization (10 generators, 45 pairs, 27 prompts) |
| 3.4-F | `pre-registered` | none | Accurate — correctly deferred, dependent on B |

No further status errors found. The registry is currently in good shape — better shape than the prior audit's own narrative about it.

---

## 3. Evidence / decision registry validation

**No standalone "evidence registry" file exists.** `Evaluation/reports/decision_registry.md` + `hypothesis_registry.json` jointly serve that role: each decision entry cites supporting hypothesis IDs and benchmark file paths. This is a reasonable structure, but it means "evidence registry completeness" has to be assessed as "are decision_registry.md's citations accurate," which is where this audit found its most consequential finding.

### Headline finding: a stale benchmark number has propagated into the production decision record

`decision_registry.md` entry #2 ("Qwen2.5-0.5B as default generator") and entry #3 ("Gemma-3n-E2B as optional quality generator") both cite:

> "40.9 tok/s vs gemma-3n-e2b 7.2 tok/s (p<0.0001, d=17.7)"

The same 7.2 tok/s / 12.77s / 0.771-cosine figures also appear in `Evaluation/reports/final_recommendation.md` (§Executive Summary, §Throughput, §Recommended Default/Optional Backend — at least 6 separate citations) and `Evaluation/reports/statistical_analysis.md` (the report, not the JSON) §Confidence Intervals, §Pairwise Statistical Tests.

I recomputed the mean directly from the current on-disk checkpoint, `Evaluation/results/candidates/gemma-3n-e2b/raw.json` (27 per-prompt records):

```
mean(tokens_per_second across 27 prompts) = 8.426315531738439
mean(generate_time across 27 prompts)     = 10.647178106837803
```

This exactly matches the `gemma-3n-e2b` entry already present in the current `Evaluation/results/leaderboard.json`:

```json
"tokens_per_second_mean": 8.426315531738439,
"generate_time_mean": 10.647178106837803,
"meaning_cosine_mean": 0.7691972282799807
```

So **`leaderboard.json` is correct and traceable** (confirmed independently by `validate_checkpoints.py`'s `check_generation_traceability`, which reported zero findings against it — see §5). The problem is specifically that three narrative documents — `final_recommendation.md`, `statistical_analysis.md` (report), and `decision_registry.md` — were generated at git commit `377d6738af33a9fa34ab28e6edddd3d0561ee45c` (timestamped `2026-07-14T02:23:13Z` per the statistical_analysis.md header) from an earlier version of the gemma-3n-e2b checkpoint, and were never regenerated after the checkpoint was updated.

**Old value (stale, still cited):** 7.2 tok/s · 12.77s generate time · 0.771 cosine
**Current value (on disk, in leaderboard.json):** 8.43 tok/s · 10.65s generate time · 0.769 cosine

**Materiality:** the *decision* (Qwen2.5-0.5B as default) is very likely still correct — Qwen at 40.9 tok/s is still ~4.9x faster than the corrected 8.43 tok/s, not materially different from the previously-claimed 5.7x. This is not a "the wrong model was chosen" finding. It is a "the evidentiary citation in the production decision record no longer matches the artifact it claims to be citing" finding, in a document explicitly designed to be the audit trail bridging science to engineering. That's exactly the kind of drift a decision registry exists to prevent, and it happened anyway.

### Known, already-documented bug (for completeness, not new)

`throughput_discrepancy.md` already root-causes a separate issue: MiniLM's leaderboard throughput (1980 emb/s) vs. its `benchmark.json` (1015 emb/s), attributed to warm- vs. cold-cache runs. This is not new — see §5 for how the validator now shows the same class of defect is more widespread than that single document describes.

---

## 4. Statistical assumptions

Two independent analysis pipelines exist, and they are not at the same level of rigor.

**Generation-side (`Evaluation/scripts/statistical_analysis.py`) is correctly wired.** It performs bootstrap CIs (10,000 resamples), Mann-Whitney U, Cohen's d, Bonferroni correction, Spearman tradeoff correlation, and K-means clustering, and its output (`statistical_analysis.md`/`.json` for generation) shows real p-values and effect sizes (e.g., `generate_time`: U=37, p<0.0001, d=-3.259).

**Embedding-side (`Evaluation/scripts/embedding_analyze.py`, 538 lines, untracked) defines the same toolkit but never uses it.** Confirmed by direct grep — each function appears exactly once, at its own `def` line, with zero call sites elsewhere in the file:

```
38:  def bootstrap_ci(data, confidence=0.95, n_boot=10000):
53:  def cohens_d(a, b):
63:  def mann_whitney_u(a, b):
84:  def bonferroni_correct(p_values):
```

The function that's actually invoked for backend-vs-backend comparison, `analyze_pairwise()` (line 119), computes raw arithmetic differences only (`score_diff`, `quality_diff`, etc.) plus a boolean `a_dominates_b`. There is no significance test and no effect size anywhere in the embeddings pairwise output — confirmed against the snapshot's `statistical_analysis.json`, whose `pairwise` block contains only diff floats; `p_value` appears exclusively under `tradeoffs.correlations` (Spearman, n=6/8 candidates), which is a different, correctly-computed analysis.

With 8 embedding backends currently on the leaderboard (28 possible pairs), presenting pairwise dominance claims with zero significance testing and zero multiple-comparisons correction is a real methodological gap — the dead `bonferroni_correct` function is sitting right there, unused, for exactly this problem.

**Neither untracked analysis script (`embedding_analyze.py`, `statistical_analysis.py`) imports the tracked shared module `Evaluation/scripts/eval_stats.py`** (commit `1eafa46 eval: shared eval_stats module + tests (DRY for Stage 3.4/3.5)`, confirmed by `git log`). Grep of both files' import statements found no reference to `eval_stats`. The shared module exists specifically to prevent this kind of duplication and its use isn't happening — worth reconciling if `eval_stats.py` is meant to be the canonical implementation going forward.

**Seeds/determinism:** fixed seeds (`np.random.default_rng(42)`, `random_state=42`) are used consistently across the bootstrap/K-means code paths that *do* exist, and the stability benchmark's variant generation is deterministic by design (rule-based, not RNG-driven). No reproducibility concern here — noting it because an audit should report what's healthy, not only gaps.

---

## 5. Provenance completeness

`Evaluation/scripts/validate_checkpoints.py` had never been executed before this audit — no captured output, log, or `--json` artifact existed anywhere in the repository prior to this run. It was run in default (non-strict) mode, writing its machine-readable report only to the audit's scratch directory (not into `Evaluation/`), per this audit's no-write constraint:

```
python3 Evaluation/scripts/validate_checkpoints.py --json <scratch>/validate_checkpoints_output.json
```

**Result: exit code 1 (FAIL). 15 failures, 28 warnings, 14 notes.**

### 15 FAILs — all traceability, all embedding-side, wider than previously documented

The known MiniLM-throughput bug (`throughput_discrepancy.md`) turns out to be one symptom of a broader defect: **three** embedding backends (`all-MiniLM-L6-v2`, `multilingual-e5-small`, `bge-small-en-v1.5`) each have **five** orphaned aggregate fields in `leaderboard.json` that don't re-derive from their own `benchmark.json` checkpoint:

| Backend | Field | Leaderboard says | Checkpoint re-derives |
|---|---|---|---|
| all-MiniLM-L6-v2 | embeddings_per_second | 1980.07 | 1015.15 |
| all-MiniLM-L6-v2 | cold_load_time | 8.10 | 7.57 |
| all-MiniLM-L6-v2 | warm_encode_ms | 129.13 | 95.43 |
| all-MiniLM-L6-v2 | peak_rss_mb | 497.28 | 505.69 |
| all-MiniLM-L6-v2 | stability_mean | 0.86792 | 0.86803 |
| multilingual-e5-small | embeddings_per_second | 1490.71 | 526.29 |
| multilingual-e5-small | cold_load_time | 8.54 | 9.13 |
| multilingual-e5-small | warm_encode_ms | 155.19 | 220.13 |
| multilingual-e5-small | peak_rss_mb | 1070.20 | 1036.64 |
| multilingual-e5-small | stability_mean | 0.96907 | 0.96927 |
| bge-small-en-v1.5 | embeddings_per_second | 1207.67 | 556.72 |
| bge-small-en-v1.5 | cold_load_time | 10.15 | 7.32 |
| bge-small-en-v1.5 | warm_encode_ms | 227.86 | 180.74 |
| bge-small-en-v1.5 | peak_rss_mb | 547.39 | 550.13 |
| bge-small-en-v1.5 | stability_mean | 0.94040 | 0.94084 |

The `stability_mean` and `peak_rss_mb` deltas are small (rounding/measurement noise, not concerning on their own), but the `embeddings_per_second` deltas are large and directionally consistent with `throughput_discrepancy.md`'s warm/cold-cache explanation — for all three backends, the leaderboard value is roughly 2x the checkpoint value, which fits a "leaderboard captured a warm-cache streaming run; benchmark.json was later overwritten by a cold-cache non-streaming run" pattern. **This is the same root cause as the documented MiniLM case, just not previously recognized as affecting two additional backends.**

Generation-side traceability (`check_generation_traceability`, which uses `tokens_per_second_mean`, `generate_time_mean`, `meaning_cosine_mean`, etc.) produced **zero findings** — `Evaluation/results/leaderboard.json` is fully traceable to its checkpoints. This is worth stating plainly: the validator's scope is JSON-checkpoint-to-JSON-leaderboard traceability, and by that measure the generation leaderboard is clean. It has no way to detect the §3 finding (stale numbers in *prose* documents) — that's a blind spot in the validator's coverage, not a bug in the validator, but worth knowing when deciding whether "the validator passes" should be read as "the reports are accurate."

### 28 WARNs

- 1x `corpus-freeze`: no `Evaluation/corpora/MANIFEST.sha256` — corpora not frozen (see §6).
- 25x `provenance`: "pre-provenance legacy artifact" — every embedding backend benchmarked before `provenance.py` landed (commit `a85bc73`), plus all 16 generation-candidate `metadata.json` files, lack the provenance block. This is expected for pre-existing artifacts and not itself a defect; new runs (per the live PID 82243 process) should be provenance-stamped going forward, which `provenance.py`'s design supports.
- 2x `embedding-checkpoints`: `bge-small-en-v1.5` and `multilingual-e5-small` are missing `metadata.json` (present for their siblings) — matches the earlier finding that these two directories are structurally inconsistent with the rest.

### 14 INFOs

Mostly `generation-checkpoints` notes recording *why* 8 of 18 generation candidates never produced a `raw.json` (wrong repo name in fixture ×3, download timeout ×2, no compatible instruct conversion ×1, interrupted download ×2) — these are correctly captured as terminal failures with reasons, not silent gaps. Also 6 `embedding-checkpoints` INFOs noting archived failed attempts are being preserved rather than silently discarded — good practice.

---

## 6. Reproducibility concerns

1. **Corpora are not frozen.** `Evaluation/scripts/freeze_corpora.py` and `freeze_stage_3_4.py` exist (both dated 2026-07-14, ~04:35–04:36 local) but have not been run — no `Evaluation/corpora/MANIFEST.sha256` exists on disk. Running `validate_checkpoints.py --strict` today would hard-fail on this. The presence of freeze scripts suggests this is an imminent, planned step (likely "Gate C" per the validator's own warning message), not an oversight — but as of this snapshot, hypotheses evaluated against the current corpora are technically evaluated against an unfrozen, mutable input.
2. **A benchmark process is live during this audit.** PID 82243 is actively adding embedding candidates (confirmed: `bge-base-en-v1.5` and `multilingual-e5-base` were added to `leaderboard.json` between the earlier reconnaissance pass and this snapshot, growing candidate count from 7 → 8). This is expected/healthy (Fable's ongoing work), but it means "missing evidence" findings below must be read as of a moving target, not a fixed defect count.
3. **`validate_checkpoints.py` had never been run before this audit** — meaning the 15 traceability failures in §5 have existed, undetected, through however many downstream reports and decisions were written against the affected leaderboard rows. There's no CI/pre-commit gate currently forcing this validator to run.
4. **`embedding_analyze.py` and `statistical_analysis.py` (both scripts, not just their outputs) are untracked** — zero commit history, meaning the dead-code statistical gap in §4 has not been through any code review or commit gate.
5. **Determinism is fine where it matters:** fixed seeds throughout the analysis layer (§4); no action needed here.

---

## 7. Documentation synchronization

| Doc | Finding |
|---|---|
| `/README.md` | Mentions the embedding backend once (BGE-small-en-v1.5 line) but never mentions `GenerationEval`, Stage 3.4, candidates v2/v3, or the checkpoint validator. `Sources/GenerationEval/` exists as a sibling executable to `EmbeddingBench`/`SemanticEval` (added via the `Package.swift` diff on this branch) but isn't listed in the README's repository-layout section. |
| `/CLAUDE.md` | Zero mentions of "embed," "eval," "benchmark," or "Stage" anywhere (grep-confirmed). This is the file that's supposed to orient a fresh session to the project, and it currently says nothing about a body of work with 6+ report documents and 16+ backend benchmarks. |
| `docs/architecture/ROADMAP.md:65-69` | States Stage 3.4 results live at `Evaluation/results/stage_3_4/` — the actual layout is flat, under `Evaluation/results/` and `Evaluation/results/embeddings/` (`Evaluation/results/stage_3_4/` does hold the RQ2–RQ4 analysis JSONs specifically, so the claim is partially true for those three files but not for the leaderboard/statistical-analysis artifacts this audit spent most of its time on — worth tightening the wording). Marks Stage 3.5 `□` (not started), but `Evaluation/results/candidates/`, `docs/reviews/phase-3.5-stall-watchdog-review.md`, and the `policy_registry` block already inside `hypothesis_registry.json` (Fast/Balanced/Quality/Adaptive policies, fully specified) all indicate Stage 3.5 work is already underway in some form. |
| `docs/Math.md:96` | States "These sections align with the Stage 3.4 and Stage 3.5 evaluation framework" but the document never defines CKA, SVCCA, or Procrustes distance — despite these being the actual RQ2 methods in `embedding_space_analysis.json` (commit `c25172f`, per prior audit). Math.md's §9 covers bootstrap CIs, Mann-Whitney U, Cohen's d, Pareto frontiers, and pre-registration — real methods used elsewhere — but the specific geometry math backing the CKA=0.96 etc. numbers quoted in the prior audit has no written definition anywhere in the docs. |
| `stage_3_4_audit.md` (prior audit) | Its own Summary Table is stale relative to the registry it describes — see §1. |

---

## 8. Missing evidence list

- **9 of 17 total embedding backend directories are not aggregated** into `leaderboard.json`/`summary.csv`/`statistical_analysis.json` as of this snapshot (8 now in leaderboard; `gte-base-en-v1.5`, `gte-large-en-v1.5`, `jina-embeddings-v3`, `nomic-embed-text-v1.5`, `snowflake-arctic-embed`, `stella_en_400M_v5`, and the two `-mlx` runtime variants have `benchmark.json` on disk but no leaderboard row). Per the prior audit and PID-82243's log, several of these are known failures (gte-base: `trust_remote_code`, gte-large: index error, nomic-embed: missing `einops`) rather than pending work — but that failure/pending distinction isn't visible from the leaderboard itself; it requires reading each `benchmark.json` or `.error` sidecar individually.
- **RQ5 (joint representations) has no evidence** — correctly deferred per the registry, pending the streaming benchmark reaching completion (currently still running via PID 82243).
- **8 of 18 generation candidates never produced `raw.json`** (see §5 INFO list) — infrastructure failures (wrong repo names, timeouts, interrupted downloads), not model-quality failures.
- **`bge-base-en-v1.5` and `multilingual-e5-base` lack stored `embedding_sample`** in their checkpoints, which is why RQ3 (cross-model agreement) only compares 2 of the models that should be eligible.
- **`statistical_analysis.json` (embeddings) has not been regenerated** since `leaderboard.json` grew from 6 → 8 candidates (currently 4.5+ hours stale relative to the leaderboard it's meant to summarize).

## 9. Unsupported claims list

- The Gemma-3n-E2B throughput/latency/cosine figures in `final_recommendation.md`, `statistical_analysis.md` (report), and `decision_registry.md` (§3 above) — currently unsupported by the on-disk checkpoint they cite.
- `docs/architecture/ROADMAP.md`'s claim that Stage 3.4 results live at `Evaluation/results/stage_3_4/` — true only for the RQ2–RQ4 analysis JSONs, not for the leaderboard/statistical-analysis artifacts.
- `stage_3_4_audit.md`'s Summary Table claim that hypothesis 3.4-A is "marked evaluated (vacuous)" in the registry — no longer true of the current registry (§1).
- Any pairwise "Model A dominates Model B" claim implied by `embedding_analyze.py`'s `analyze_pairwise()` output should be read as a raw-difference observation, not a statistically supported claim — no significance test backs it (§4).

## 10. Stale documentation list

- `/README.md` — silent on the eval harness, `GenerationEval`, and Stage 3.x entirely.
- `/CLAUDE.md` — same, and arguably more consequential since it's the project's primary orientation document.
- `docs/Math.md` §9 — claims Stage 3.4/3.5 alignment without defining the actual RQ2 geometry math (CKA/SVCCA/Procrustes) in use.
- `docs/architecture/ROADMAP.md` — Stage 3.5 marked not-started despite `policy_registry` and related artifacts already existing; results-path claim is imprecise.
- `Evaluation/reports/stage_3_4_audit.md` — Summary Table drifted from the registry it audited (§1).
- `Evaluation/reports/final_recommendation.md`, `Evaluation/reports/statistical_analysis.md` (report), `Evaluation/reports/decision_registry.md` — all three carry the stale Gemma-3n-E2B numbers (§3).

## 11. Reproducibility concerns (summary)

See §6 for detail. In brief: corpora unfrozen (freeze scripts exist but unrun), a live benchmark process makes any snapshot provisional, the checkpoint validator had never been run before this audit and immediately found 15 real failures, and the two embedding-analysis scripts carrying the statistical-methodology gap have no commit/review history. Determinism (seeds) is not a concern.

## 12. Publication-readiness checklist

| Gate | Status | Basis |
|---|---|---|
| All leaderboard rows traceable to checkpoints | **FAIL** | 15 orphaned values across 3 embedding backends (§5) |
| Primary comparisons have significance testing + effect sizes | **PARTIAL** — PASS (generation), FAIL (embeddings) | §4 |
| Multiple-comparisons correction applied where multiple pairs compared | **PARTIAL** — PASS (generation, Bonferroni), FAIL (embeddings, function unused) | §4 |
| Corpora frozen with integrity manifest | **FAIL** | No `MANIFEST.sha256`; freeze scripts exist but unrun (§6) |
| Provenance stamped on all evaluated artifacts | **FAIL** (for legacy artifacts) / **N/A going forward** | 25 pre-provenance WARNs, all pre-dating `provenance.py` (§5) |
| Decision registry citations match current evidence | **FAIL** | Gemma-3n-E2B stale numbers in 2 of 6 entries (§3) |
| Hypothesis registry statuses match underlying evidence | **PASS** | §2 — no discrepancies found in current registry |
| README/CLAUDE.md describe the evaluation program | **FAIL** | §7 |
| Validator run and clean prior to any "final" claim | **FAIL** (first run, and it failed) | §5 |
| Analysis code under version control and reviewed | **FAIL** | `embedding_analyze.py`, `statistical_analysis.py` both untracked (§4, §6) |

**Overall: not publication-ready.** The underlying scientific findings for RQ2/RQ3/RQ4 (per the prior audit) are directionally sound and appropriately caveated as preliminary. The blocking issues are process/traceability issues, not findings issues: fix the 3-backend orphaned-value bug the same way `throughput_discrepancy.md` diagnosed the MiniLM case, regenerate the three narrative reports that cite stale Gemma-3n-E2B numbers, wire the existing (but unused) bootstrap/Mann-Whitney/Cohen's d/Bonferroni functions into the embeddings pairwise comparison (or delete them if `eval_stats.py` is meant to replace them), run `freeze_corpora.py` before treating any current result as final, and bring the top-level docs up to date.

---

## Appendix: files in the frozen snapshot referenced by this audit

Copied at 2026-07-14T09:37Z from working tree at git HEAD `a65886d092c14e9105c030cfec1189c26c6939ed`:
`Evaluation/results/embeddings/leaderboard.json`, `Evaluation/results/embeddings/statistical_analysis.json`, `Evaluation/results/embeddings/summary.csv`, `Evaluation/results/candidates/gemma-3n-e2b/raw.json`, `Evaluation/results/leaderboard.json` (generation).

Validator invocation: `python3 Evaluation/scripts/validate_checkpoints.py --json <scratch>/validate_checkpoints_output.json` (default non-strict mode; JSON report written outside the repository, not under `Evaluation/`).
