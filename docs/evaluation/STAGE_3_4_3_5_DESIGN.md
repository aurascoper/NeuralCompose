# Stage 3.4/3.5 Evaluation Design

> Offline cross-model and pipeline evaluation for NeuralCompose.
> The hypothesis registry (`Evaluation/corpora/hypothesis_registry.json`)
> and decision registry (`Evaluation/reports/decision_registry.md`) are
> the source of truth; this doc provides narrative context.

## Stage progression

| Stage | Scope | Production code changes? |
|-------|-------|---------------------------|
| 3.3 (done) | Scientific validation of individual models | No |
| 3.4 | Cross-model and cross-runtime scientific analysis | **No** — offline analysis only |
| 3.5 | Representation/pipeline validation | **No** — offline policy evaluation only |
| 4 (future) | Implement architectural changes supported by evidence | Yes |

## Hypothesis registry

Every experiment is pre-registered in `Evaluation/corpora/hypothesis_registry.json`
with a metric, success criterion, expected effect size, and status before
any code is written. The registry has two sections:

- `stage_3_4`: 6 hypotheses (A–F) covering runtime consistency, joint
  embeddings, embedding-space analysis, cross-model agreement, generator
  comparison, and offline fusion.
- `stage_3_5`: 6 hypotheses (A–E, P) covering joint embedding selection,
  adaptive routing, pipeline benchmark, cascaded generation,
  confidence-based selection, and pipeline policy comparison.

## Policy registry

The `policy_registry` in the hypothesis registry defines four named
policies for Stage 3.5 comparison:

| Policy | Latency budget | Use case |
|--------|---------------|----------|
| Fast | 2.0s | Short commands, high-frequency interaction |
| Balanced | 5.0s | General-purpose communication |
| Quality | 15.0s | Complex rewrites, technical-term preservation |
| Adaptive | 2.0–15.0s per query | Production intent — maximizes communication rate |

These are evaluated offline using the benchmark framework only. They do
NOT modify `PredictorFactory`, routing logic, or any production pipeline.

## Decision registry

`Evaluation/reports/decision_registry.md` bridges scientific findings to
future engineering work (Stage 4). Each entry captures:

- Decision, Evidence, Supporting hypotheses, Supporting benchmark(s),
  Confidence (High/Medium/Low), Status (Accepted/Deferred/Rejected/Pending)

Seeded with 6 entries from Stage 3.3 findings. Updated after every Stage
3.4/3.5 analysis completes.

## Work packages

| WP | Stage | Script | Description |
|----|-------|--------|-------------|
| A | 3.4 | `cross_runtime_consistency.py` | Cosine drift between Python/CoreML/MLX |
| B | 3.4 | `joint_embeddings.py` (deferred) | Concatenation, weighted, PCA, late fusion |
| C | 3.4 | `embedding_space_analysis.py` | CKA, SVCCA, Procrustes, neighborhood overlap |
| D | 3.4 | `cross_model_agreement.py` | Jaccard overlap of top-k neighbor sets |
| E | 3.4 | `generator_comparison.py` | Pairwise cosine, BLEU-4, exact match |
| F | 3.4 | `joint_embeddings.py` (deferred) | Fusion strategy comparison |
| A–E, P | 3.5 | `run_stage_3_5.py` | Pipeline benchmark, routing, cascade, confidence, policies |

## How to run

```sh
# Phase 1A (immediate — existing artifacts only)
python3 Evaluation/scripts/run_stage_3_4.py

# Phase 1B (deferred — after streaming embedding benchmark completes)
python3 Evaluation/scripts/joint_embeddings.py --top-k 3
python3 Evaluation/scripts/run_stage_3_4.py --include-deferred

# Stage 3.5 (deferred — after Phase 1B)
python3 Evaluation/scripts/run_stage_3_5.py

# Unit tests
python3 Tests/eval/test_eval_stats.py
python3 Tests/eval/test_embedding_space.py
```

## How results inform Stage 4

The decision registry is the bridge. When Stage 3.4/3.5 analyses
complete, the aggregate runners update the registry with evidence,
confidence levels, and statuses. Stage 4 implementation decisions should
reference specific decision registry entries — not raw benchmark JSON —
so the chain from hypothesis → evidence → decision → implementation is
auditable.