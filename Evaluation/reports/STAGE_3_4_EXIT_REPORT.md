# Stage 3.4 Exit Report

**Generated:** 2026-07-14T12:15:05.028626+00:00 — by `generate_exit_report.py` from primary artifacts (do not hand-edit)
**Git:** `5da17659c62b` on `research/lit-review-methodology` (dirty)
**Machine:** Apple M4, macOS 26.5.2, 16.0 GB

## Research question status

| RQ | Question | Verdict | Basis |
|----|----------|---------|-------|
| RQ1 | Runtime equivalence | **GO-WITH-CONDITIONS** | 4 cross-runtime comparison(s) on disk; Evaluated 2026-07-14: 4 cross-runtime comparisons on identical weights (MiniLM python vs mlx-swift; bge-small python vs mlx-swift, python vs coreml, mlx-swift vs coreml), all mean cosine = 1.000000, drift = none (N=10 stored samples per model). Two Swift-harness defects were caught by this analysis and fixed before the final runs (MLXEmbedders omits the segment-0 token-type embedding when ids are nil; Pooling's cls prefers the tanh pooler head over the raw CLS state). python mlx_lm remains unable to load BERT encoders, so the MLX runtime evidence is Swift MLXEmbedders ('mlx-swift'). |
| RQ2 | Embedding-space geometry | **GO-WITH-CONDITIONS** | Pilot study: N=10 stored samples. CKA biased high at small N. Needs full-corpus analysis for strong conclusions. |
| RQ3 | Cross-model agreement | **GO-WITH-CONDITIONS** | Refreshed 2026-07-14: 3 models with stored samples (MiniLM, bge-small, bge-base), pairwise mean Jaccard@5 0.66-0.80, N=10 texts, k=5 from pool of 9. Still a pilot: needs the full corpus and more models for strong conclusions. |
| RQ4 | Generator comparison | **GO-WITH-CONDITIONS** | Strong evidence: 10 generators, 45 pairs, 27 prompts. Mean cosine ~0.55 (divergent). Per-category breakdown available. |
| RQ5 | Joint representations (deferred by design) | **DEFERRED** | pre-registered by design; joint_embeddings.py not yet implemented |

## Hypothesis status (Stage 3.4 registry)

| Hypothesis | Status | Success criterion | Note |
|------------|--------|-------------------|------|
| 3.4-A-runtime-consistency | evaluated | Mean cosine >= 0.999 (no drift) for at least one non-Python runtime | Evaluated 2026-07-14: 4 cross-runtime comparisons on identical weights (MiniLM python vs mlx-swift; bge-small python vs mlx-swift, python vs coreml, mlx-swift vs coreml), all mean cosine = 1.000000, drift = none (N=10 stored samples per model). Two Swift-harness defects were caught by this analysis and fixed before the final runs (MLXEmbedders omits the segment-0 token-type embedding when ids are nil; Pooling's cls prefers the tanh pooler head over the raw CLS state). python mlx_lm remains unable to load BERT encoders, so the MLX runtime evidence is Swift MLXEmbedders ('mlx-swift'). |
| 3.4-B-joint-embeddings | pre-registered | >= 5% improvement in separation_ratio over best single model |  |
| 3.4-C-embedding-space | evaluated | CKA >= 0.7 between at least one pair (evidence of convergent representation) | Pilot study: N=10 stored samples. CKA biased high at small N. Needs full-corpus analysis for strong conclusions. |
| 3.4-D-cross-model-agreement | evaluated | Mean Jaccard >= 0.5 for at least one pair (sufficient agreement for ensemble) | Refreshed 2026-07-14: 3 models with stored samples (MiniLM, bge-small, bge-base), pairwise mean Jaccard@5 0.66-0.80, N=10 texts, k=5 from pool of 9. Still a pilot: needs the full corpus and more models for strong conclusions. |
| 3.4-E-generator-comparison | evaluated | Mean pairwise output cosine >= 0.8 (high agreement) OR < 0.6 (divergent, ensemble-worthy) | Strong evidence: 10 generators, 45 pairs, 27 prompts. Mean cosine ~0.55 (divergent). Per-category breakdown available. |
| 3.4-F-offline-fusion | pre-registered | At least one fusion method improves retrieval_top1 by >= 2% over best single model |  |

## Evidence summary

- **Embedding track:** 11 of 17 candidates evaluated; 6 terminal failures (recorded with causes below)
- **Generation track:** 16 of 18 candidates evaluated; 2 failed/unavailable/pending
- **Embedding leaderboard #1:** all-MiniLM-L6-v2 (python), score 0.855 of 14 entries
- **Generation leaderboard #1:** tinyllama-1.1b, score 0.843 of 16 entries
- `results/stage_3_4/cross_runtime_consistency.md`
- `results/stage_3_4/cross_model_agreement.md`
- `results/stage_3_4/embedding_space_analysis.md`
- `results/stage_3_4/generator_comparison.md`

## Blocked / failed work (recorded evidence, not silently dropped)

- embedding/jina-embeddings-v3: 'XLMRobertaLoRA' object has no attribute 'all_tied_weights_keys'
- embedding/gte-base-en-v1.5: repo_or_file_missing
- embedding/gte-large-en-v1.5: index 4346922624 is out of bounds for dimension 0 with size 7
- embedding/stella_en_400M_v5: please install xformers
- embedding/bge-small-en-v1.5-mlx: Model type bert not supported.; weight_size_mismatch
- embedding/all-MiniLM-L6-v2-mlx: Model type bert not supported.; weight_size_mismatch
- generation/gemma-3-4b: smoke_test_failed
- generation/openelm-3b: unavailable: mlx-community has no OpenELM-3B instruct conversion (only ba

## Deferred work (by design)

- RQ5 (3.4-B joint embeddings, 3.4-F offline fusion): deferred until the embedding benchmark is complete so fusion candidates are chosen from full evidence; `joint_embeddings.py` intentionally not implemented (`run_stage_3_4.py --include-deferred` must not be used)
- Stage 3.5 policy execution (Fast/Balanced/Quality/Adaptive): pre-registered in `policy_registry`, no implementation

## Audit findings (validator)

**PASS** — 0 failure(s), 18 warning(s)

## Reproducibility

**FAIL** — controlled side-by-side reruns vs canonical checkpoints, tolerances quality |Δ|≤0.005 abs / perf ±20% rel (`results/repro/repro_report.md`)

## Stage 3.5 prerequisites

- [x] Embedding benchmark complete (every candidate terminal)
- [x] Generation benchmark complete (every candidate terminal)
- [x] RQ1 evidence exists (≥1 cross-runtime comparison)
- [x] Validator passes (no FAIL findings)
- [ ] Reproducibility report PASS
- [ ] Corpora frozen (MANIFEST.sha256)
- [ ] Evidence frozen (Evaluation/stage_3_4/frozen/)

## Final recommendation

Stage 3.4 is **not ready to close**. Remaining:
- Reproducibility report PASS
- Corpora frozen (MANIFEST.sha256)
- Evidence frozen (Evaluation/stage_3_4/frozen/)
