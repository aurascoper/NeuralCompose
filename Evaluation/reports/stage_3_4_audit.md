# Stage 3.4 Scientific Progress Audit

Date: 2026-07-14
Reviewer: GLM-5.2 (scientific reviewer role)
Repository: ~/Developer/NeuralCompose

---

## Verdict

Stage 3.4 is already underway as a scientific program. Four of five
research questions have completed evidence on disk; one is deferred by
design. The hypothesis registry is not merely prepared: four of six
Stage 3.4 hypotheses have been marked "evaluated" with concrete
artifacts, and the decision registry has been updated with a timestamp
from the Stage 3.4 aggregate run (2026-07-14T06:42:04Z).

The program has also produced unanticipated findings that are not in the
hypothesis registry. Those are catalogued below as exploratory
observations.

---

## RQ1: Runtime Equivalence

> Do identical models behave the same across runtimes?

### Evidence

Artifact: `Evaluation/results/stage_3_4/cross_runtime_consistency.json`
Result: n_comparisons = 0. No models have been benchmarked in multiple
runtimes successfully.

Two models have multi-runtime directory structure
(`all-MiniLM-L6-v2-mlx` with `python/` and `mlx/`, `bge-small-en-v1.5-mlx`
with the same), but both failed in both runtimes:

- Python runtime: `ignore_mismatched_sizes=False` error: the model
  config has a mismatch between the tokenizer vocab size and the
  embedding layer dimension.
- MLX runtime: `No module named 'mlx'`: the MLX Python package is not
  installed in the venv (it is linked via SwiftPM for the app, but the
  embedding benchmark runs in Python and needs `mlx` as a pip
  dependency).

### Hypothesis status

3.4-A-runtime-consistency: marked "evaluated" in the registry, but the
evaluation is vacuous: it ran, produced no comparisons, and wrote a
valid report saying "no multi-runtime data." The hypothesis itself is
completely untested. Marking it "evaluated" is a status error.

### What would fix this

1. Fix the `ignore_mismatched_sizes` issue in the Python embedding
   benchmark (likely a tokenizer/model config mismatch in the `-mlx`
   model variants).
2. Install `mlx` Python package in the venv (`pip install mlx`).
3. Re-run the embedding benchmark on the `-mlx` model directories in
   both Python and MLX runtimes.
4. Re-run `cross_runtime_consistency.py`.

---

## RQ2: Geometry

> Study the embedding spaces, not just the embeddings.

### Evidence

Artifact: `Evaluation/results/stage_3_4/embedding_space_analysis.json`
Result: 3 models with stored samples, 3 pairwise comparisons, all
metrics computed successfully.

| Pair | CKA | SVCCA | Procrustes | NN Overlap | Cluster Purity |
|------|-----|-------|------------|------------|----------------|
| MiniLM vs e5-small | 0.962 | 0.859 | 0.024 | 0.686 | 0.80 |
| MiniLM vs bge-small | 0.957 | 0.919 | 0.025 | 0.662 | 0.80 |
| e5-small vs bge-small | 0.966 | 0.856 | 0.021 | 0.668 | 1.00 |

Intrinsic dimensionality (participation ratio):
- MiniLM: 7.18
- e5-small: 7.02
- bge-small: 6.73

### Hypothesis status

3.4-C-embedding-space: marked "evaluated." Success criterion was
"CKA >= 0.7 between at least one pair." All three pairs have CKA >
0.95. Hypothesis is supported with large margin.

### Limitations

Only 10 texts per model (the stored `embedding_sample` from
`benchmark.json`). This is the first 10 corpus texts, not a full
analysis. With N=10:

- CKA is biased high in small samples: the 0.96 values may not
  generalize to larger corpora.
- Procrustes disparity is small (0.02-0.03) but this is expected when
  N << dimension; the alignment is underdetermined.
- Cluster purity at N=10 with 5 clusters means each cluster has ~2
  points; purity is nearly degenerate.
- Intrinsic dimensionality of ~7 on 10 samples with 384 dimensions is
  dominated by the sample-to-dimension ratio, not the true geometry.

These are valid preliminary results, but the small sample size is a
known limitation that should be documented and revisited with full
corpus analysis.

### What is missing

The plan called for trustworthiness, continuity, spectral decay, and
manifold overlap. These were not implemented. The current script
covers CKA, SVCCA, Procrustes, neighborhood overlap, cluster purity,
and intrinsic dimensionality; 6 of the 10 metrics in the design.

---

## RQ3: Agreement

> Compare decisions, not vectors.

### Evidence

Artifact: `Evaluation/results/stage_3_4/cross_model_agreement.json`
Result: 2 models (MiniLM, e5-small), 1 pair, 10 texts, k=5 neighbors.

Mean Jaccard: 0.686. Consensus ratio: 0.686.

### Hypothesis status

3.4-D-cross-model-agreement: marked "evaluated." Success criterion was
"Mean Jaccard >= 0.5 for at least one pair." The single pair achieves
0.686. Hypothesis is supported.

### Limitations

Only 2 models were compared (bge-base was in the top-3 but had no
stored embedding sample). With 2 models, Jaccard and consensus are
identical; there is no "consensus across all models" beyond the
pairwise overlap. The design called for 3+ models.

Additionally, with only 10 texts and k=5, the neighbor sets are drawn
from 9 items (excluding self). A Jaccard of 0.686 means ~4-5 of 5
neighbors overlap on average; but with such a small pool, random
overlap would be substantial. The signal is weak.

### What is missing

- bge-base and multilingual-e5-base lack `embedding_sample` in their
  benchmark.json. These need to be re-run with sample storage enabled.
- Full corpus analysis (not just 10 stored samples) would require model
  re-loading.
- The design mentioned Jina and 17+ models; only 7 embedding models
  are in the leaderboard, and only 5 have stored samples.

---

## RQ4: Generator Comparison

> Same prompts, multiple generators.

### Evidence

Artifact: `Evaluation/results/stage_3_4/generator_comparison.json`
Result: 10 generators, 45 pairs, 27 prompts per pair.

### Hypothesis status

3.4-E-generator-comparison: marked "evaluated." Success criterion:
"Mean pairwise output cosine >= 0.8 (high agreement) OR < 0.6
(divergent, ensemble-worthy)."

The overall mean cosine across all 45 pairs is approximately 0.55
(estimated from the pair data). This falls in the diverent range
(< 0.6), supporting the "ensemble-worthy" branch of the hypothesis.

### Key findings

Same-family pairs (gemma-gemma, llama-llama, qwen-qwen, phi-phi) have
mean cosine 0.605, while cross-family pairs average 0.528. The delta
(0.077) is modest but consistent; family membership explains some
output similarity but not much.

The only exact match in 45 pairs × 27 prompts is 1/27 between
gemma-3n-e2b and gemma-3n-e4b (the same model at different quantization
levels). No cross-family exact matches occurred.

Per-category agreement (sorted by cosine):

| Category | Mean Cosine | Mean BLEU-4 |
|----------|------------|-------------|
| technical-term-preservation | 0.667 | 0.036 |
| capitalization | 0.646 | 0.026 |
| command-reformulation | 0.596 | 0.010 |
| punctuation-restoration | 0.526 | 0.012 |
| instruction-following | 0.521 | 0.014 |
| filler-removal | 0.464 | 0.006 |
| concise-rewrite | 0.434 | 0.014 |

Structured tasks (capitalization, technical-term-preservation) show
higher cross-model agreement than open-ended tasks (concise-rewrite,
filler-removal). This is expected but had not been pre-registered as a
hypothesis.

### What is missing

8 additional generation candidates have metadata but no `raw.json`:
they failed due to download timeouts, wrong repo names, or interrupted
downloads. These are not lost data but incomplete data: the candidates
list was ambitious (18 total), and 10 completed.

The BLEU-4 scores are universally low (mean ~0.02), suggesting the
simplified BLEU implementation may be too strict, or that the prompts
genuinely produce diverse outputs. A human evaluation sample would
clarify whether low BLEU means meaningful disagreement or just
surface-form variation.

---

## RQ5: Joint Representations

> Combine top-K models.

### Evidence

None. No scripts have been written or run for RQ5.

### Hypothesis status

3.4-B-joint-embeddings: "pre-registered" (correct).
3.4-F-offline-fusion: "pre-registered" (correct).

### Dependency

These are deferred until the streaming embedding benchmark completes.
The streaming benchmark is NOT currently running (no benchmark
processes detected). The log files show it completed or was
interrupted:

- `streaming_benchmark.log` ends with a list of recommended re-downloads
  (qwen2.5-0.5b, gemma-3n-e2b).
- `streaming_benchmark_full.log` ends mid-download of gemma-3-4b.
- `run_remaining.log` ends mid-download of SmolLM2-1.7B.

The streaming benchmark appears to have been interrupted, not
completed. The leaderboard has 7 embedding models, but the candidate
list in `embedding_bench_candidates_v1.json` may have more. Until the
benchmark is re-run to completion, RQ5 stays deferred.

---

## Streaming Benchmark Status

Not running. No `EmbeddingBench`, `GenerationEval`, or `streaming`
processes are alive. The logs show interruption mid-download.

The embedding leaderboard has 7 evaluated models, 4 failed models
(gte-base: trust_remote_code, gte-large: index error,
nomic-embed: missing einops, and the two -mlx variants). 5 models have
stored embedding samples suitable for the existing Stage 3.4 analyses.

The generation leaderboard has 10 evaluated models, 8 failed/incomplete
(mostly download timeouts and wrong repo names).

---

## Anomalies and Issues

### 1. Embedding stability scores are all 0.000

Every model in the embedding leaderboard has `stability_score: 0.000`.
This is almost certainly a calculation error, not a real finding:
MiniLM has a documented stability of 0.868 in the Stage 3.3 report
(`final_recommendation.md`). The streaming benchmark's stability
calculation appears to be broken or using a different definition.

This affects the overall_score calculation if stability is a
component, meaning the leaderboard rankings may be partially wrong.

### 2. MiniLM throughput discrepancy

The leaderboard reports MiniLM at 1980 emb/s, but the stored
benchmark.json says 1015 emb/s. The discrepancy may be from a
different run or a reporting bug in the leaderboard aggregation.

### 3. Hypothesis 3.4-A is falsely marked "evaluated"

The cross-runtime consistency script ran, found no multi-runtime data,
and wrote a valid report. But the hypothesis; "do CoreML and MLX
runtime conversions introduce cosine drift?"; was never actually
tested. The status should be "pre-registered" or "blocked," not
"evaluated."

---

## Exploratory Observations

These are not in the hypothesis registry. They are tagged per the
Incubator convention.

### Observation 1: Generator family effect [Observation]

Same-family generator pairs have higher cosine (0.605) than
cross-family pairs (0.528), but the effect is modest (delta = 0.077).
Family membership is a weak predictor of output similarity.

### Hypothesis 1: Family-blind ensembles are viable [Hypothesis]

If same-family and cross-family agreement differs by only 0.077, then
an ensemble that mixes families (e.g., Qwen + Gemma) should not
degrade output quality relative to a same-family pair, and may
improve diversity.

### Experiment 1: Cross-family cascade test [Experiment]

Run a cascade (Gemma draft, Qwen edit) and compare output cosine to
same-model and cross-model baselines. If the cascade output has higher
cosine to the reference than either single model, the family-blind
cascade is viable.

### Observation 2: Task structure predicts agreement [Observation]

Structured tasks (capitalization, technical-term-preservation) show
higher cross-model agreement (cosine 0.65-0.67) than open-ended tasks
(concise-rewrite, filler-removal, cosine 0.43-0.46). The task category
explains more variance in agreement than the model family.

### Hypothesis 2: Adaptive routing by task type is worthwhile [Hypothesis]

If structured tasks already show high agreement across models, routing
them to the fastest model (Qwen-0.5B) loses little quality. Open-ended
tasks, where models disagree, may benefit from a quality-tier model
(Gemma) or an ensemble. This is the Stage 3.5 adaptive routing
hypothesis, but the per-category evidence already supports it.

### Experiment 2: Per-category policy simulation [Experiment]

Score each generator per category (using the existing 27-prompt
corpus). Compute the Pareto frontier per category. If the Pareto-
optimal generator differs by category, adaptive routing by category is
justified by existing data; no new benchmark needed.

### Observation 3: Intrinsic dimensionality is low and similar [Observation]

All three embedding models have participation ratio ~7 on 10 samples.
This is likely an artifact of N=10 (the participation ratio is
bounded by N-1), but if it holds on the full corpus, it suggests all
384-dimensional models are using a ~7-dimensional effective subspace
for this corpus. If true, a 7-dimensional projection should preserve
most of the retrieval signal.

### Hypothesis 3: A 16-dimensional projection suffices for retrieval [Hypothesis]

If the intrinsic dimensionality is ~7, then PCA to 16 dimensions
should preserve >95% of the variance and >90% of the retrieval signal
(top-1 accuracy). This would make the embedding step trivially fast
and enable storage of many more corpus items in memory.

### Experiment 3: PCA dimensionality vs retrieval trade-off [Experiment]

For each embedding model, compute PCA to dimensions [4, 8, 16, 32, 64,
128, 384]. Measure top-1 retrieval accuracy at each dimension. If 16
dimensions preserves >90% accuracy, this is a production-relevant
finding for Stage 4.

### Observation 4: 8 generation candidates failed due to infrastructure, not models [Observation]

Of 18 generation candidates, 8 failed: 3 had wrong repo names in the
fixture, 2 had download timeouts, 1 had no 4-bit MLX version, and 2
were interrupted. None failed due to model quality. This means the
generation leaderboard is incomplete, and the missing models (SmolLM2,
OpenELM, Qwen3, TinyLlama, gemma-3-4b) may include viable candidates
that were never tested.

### Observation 5: Embedding stability metric is broken [Observation]

All 7 evaluated embedding models have `stability_score: 0.000` in the
leaderboard. The Stage 3.3 report documents MiniLM stability at 0.868.
The streaming benchmark's stability calculation is either not running
or computing on a different metric definition. This is a data
integrity issue, not a scientific finding.

---

## Summary Table

| RQ | Hypothesis | Status | Evidence | Quality |
|----|-----------|--------|----------|---------|
| RQ1 | 3.4-A | evaluated (vacuous) | 0 comparisons | Blocked; no multi-runtime data |
| RQ2 | 3.4-C | evaluated (supported) | 3 pairs, 6 metrics | Preliminary; N=10, 6/10 planned metrics |
| RQ3 | 3.4-D | evaluated (supported) | 1 pair, 10 texts | Weak; only 2 models, small pool |
| RQ4 | 3.4-E | evaluated (supported) | 10 generators, 45 pairs | Strong; 27 prompts, per-category breakdown |
| RQ5 | 3.4-B/F | pre-registered | None | Deferred; streaming benchmark interrupted |

---

## Is Stage 3.4 Underway?

Yes. Four of five research questions have completed evidence on disk.
The hypothesis registry has been updated. The decision registry has a
Stage 3.4 run timestamp. The aggregate runner has executed and produced
JSON and Markdown reports for RQ1-RQ4.

However, the evidence quality varies:

- RQ4 (generator comparison) is the strongest result: 10 generators,
  45 pairs, 27 prompts, per-category breakdown. This is real evidence.
- RQ2 (geometry) and RQ3 (agreement) are real but preliminary; 10
  texts and 2-3 models. The results are directionally valid but need
  full-corpus analysis to be trustworthy.
- RQ1 (runtime equivalence) is a status error; the hypothesis was
  marked "evaluated" but was never tested. No multi-runtime data
  exists.
- RQ5 (joint representations) is correctly deferred.

Stage 3.4 is underway, not merely prepared. But it is in an early
state where most analyses are running on 10-text stored samples rather
than the full corpus, and one hypothesis has a status error that should
be corrected.