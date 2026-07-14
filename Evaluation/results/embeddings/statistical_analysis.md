# NeuralCompose Embedding Benchmark — Statistical Analysis

**Generated:** 2026-07-14T12:11:51.629153+00:00
**Candidates:** 14

## Rankings by Metric

### quality_score

| Rank | Model | Runtime | Value |
|------|-------|---------|-------|
| 1 | all-MiniLM-L6-v2 | python | 0.7336 |
| 2 | bge-m3 | python | 0.6526 |
| 3 | mxbai-embed-large-v1 | python | 0.6512 |
| 4 | multilingual-e5-small | python | 0.6503 |
| 5 | multilingual-e5-large | python | 0.6496 |
| 6 | multilingual-e5-base | python | 0.6492 |
| 7 | Qwen3-Embedding-0.6B | python | 0.6469 |
| 8 | bge-small-en-v1.5 | python | 0.6467 |
| 9 | bge-base-en-v1.5 | python | 0.6444 |
| 10 | snowflake-arctic-embed | python | 0.6417 |

### stability_mean

| Rank | Model | Runtime | Value |
|------|-------|---------|-------|
| 1 | multilingual-e5-small | python | 0.9693 |
| 2 | multilingual-e5-base | python | 0.9602 |
| 3 | multilingual-e5-large | python | 0.9545 |
| 4 | snowflake-arctic-embed | python | 0.9525 |
| 5 | bge-small-en-v1.5 | python | 0.9408 |
| 6 | bge-base-en-v1.5 | python | 0.9298 |
| 7 | mxbai-embed-large-v1 | python | 0.9285 |
| 8 | nomic-embed-text-v1.5 | python | 0.9269 |
| 9 | bge-m3 | python | 0.9213 |
| 10 | Qwen3-Embedding-0.6B | python | 0.9128 |

### cold_load_time

| Rank | Model | Runtime | Value |
|------|-------|---------|-------|
| 1 | all-MiniLM-L6-v2 | mlx-swift | 0.0252 |
| 2 | bge-small-en-v1.5 | mlx-swift | 0.0342 |
| 3 | bge-small-en-v1.5 | coreml | 0.0753 |
| 4 | bge-base-en-v1.5 | python | 6.2638 |
| 5 | Qwen3-Embedding-0.6B | python | 6.3504 |
| 6 | snowflake-arctic-embed | python | 6.5346 |
| 7 | bge-small-en-v1.5 | python | 7.3178 |
| 8 | all-MiniLM-L6-v2 | python | 7.5739 |
| 9 | bge-m3 | python | 8.1033 |
| 10 | multilingual-e5-large | python | 8.1316 |

### embeddings_per_second

| Rank | Model | Runtime | Value |
|------|-------|---------|-------|
| 1 | all-MiniLM-L6-v2 | python | 1015.1475 |
| 2 | bge-small-en-v1.5 | python | 556.7179 |
| 3 | multilingual-e5-small | python | 526.2852 |
| 4 | bge-base-en-v1.5 | python | 511.1941 |
| 5 | multilingual-e5-base | python | 497.7853 |
| 6 | nomic-embed-text-v1.5 | python | 429.0162 |
| 7 | multilingual-e5-large | python | 171.7846 |
| 8 | snowflake-arctic-embed | python | 170.2137 |
| 9 | bge-m3 | python | 156.6970 |
| 10 | all-MiniLM-L6-v2 | mlx-swift | 133.5117 |

### peak_rss_mb

| Rank | Model | Runtime | Value |
|------|-------|---------|-------|
| 1 | bge-small-en-v1.5 | coreml | 282.1250 |
| 2 | bge-small-en-v1.5 | mlx-swift | 440.0781 |
| 3 | all-MiniLM-L6-v2 | mlx-swift | 446.9062 |
| 4 | all-MiniLM-L6-v2 | python | 505.6875 |
| 5 | bge-small-en-v1.5 | python | 550.1250 |
| 6 | bge-base-en-v1.5 | python | 780.1250 |
| 7 | nomic-embed-text-v1.5 | python | 899.1406 |
| 8 | mxbai-embed-large-v1 | python | 978.5625 |
| 9 | multilingual-e5-small | python | 1036.6406 |
| 10 | multilingual-e5-base | python | 1169.9062 |

### overall_score

| Rank | Model | Runtime | Value |
|------|-------|---------|-------|
| 1 | all-MiniLM-L6-v2 | python | 0.8553 |
| 2 | bge-small-en-v1.5 | python | 0.8303 |
| 3 | bge-base-en-v1.5 | python | 0.8301 |
| 4 | multilingual-e5-base | python | 0.7876 |
| 5 | multilingual-e5-small | python | 0.7836 |
| 6 | mxbai-embed-large-v1 | python | 0.7738 |
| 7 | snowflake-arctic-embed | python | 0.7718 |
| 8 | Qwen3-Embedding-0.6B | python | 0.7678 |
| 9 | nomic-embed-text-v1.5 | python | 0.7552 |
| 10 | bge-m3 | python | 0.7492 |

## Pareto Frontier

- **all-MiniLM-L6-v2 (python)**
- **bge-small-en-v1.5 (python)**
- **bge-base-en-v1.5 (python)**
- **multilingual-e5-base (python)**
- **multilingual-e5-small (python)**
- **mxbai-embed-large-v1 (python)**
- **snowflake-arctic-embed (python)**
- **Qwen3-Embedding-0.6B (python)**
- **bge-m3 (python)**
- **multilingual-e5-large (python)**
- **all-MiniLM-L6-v2 (mlx-swift)**

## Tradeoff Analysis

| Pair | Spearman ρ | p-value |
|------|-----------|---------|
| quality_latency | 0.598 | 0.0238 |
| stability_latency | 0.669 | 0.0089 |
| stability_quality | 0.410 | 0.1452 |
| memory_quality | 0.550 | 0.0417 |
| throughput_latency | 0.415 | 0.1397 |

## Runtime Comparison (Same Model, Different Runtime)

| Model | Runtime A | Runtime B | Quality Δ | Stability Δ | Latency Δ | Better |
|-------|-----------|-----------|-----------|-------------|-----------|--------|
| all-MiniLM-L6-v2 | python | mlx-swift | +0.6336 | +0.8680 | +7.55s | python |
| bge-small-en-v1.5 | python | coreml | +0.5467 | +0.9408 | +7.24s | python |
| bge-small-en-v1.5 | python | mlx-swift | +0.5467 | +0.9408 | +7.28s | python |
| bge-small-en-v1.5 | coreml | mlx-swift | +0.0000 | +0.0000 | +0.04s | coreml |

## Cross-Runtime Embedding Consistency

Compares embeddings produced by different runtimes on the same 10 corpus texts.
Mean cosine ≈ 1.000 indicates no drift between runtime conversions.

| Model | Runtime A | Runtime B | Mean Cosine | Min | Max | Std | Drift? |
|-------|-----------|-----------|-------------|-----|-----|-----|--------|
| all-MiniLM-L6-v2 | python | mlx-swift | 1.000000 | 1.000000 | 1.000000 | 0.000000 | ✓ no |
| bge-small-en-v1.5 | python | coreml | 1.000000 | 1.000000 | 1.000000 | 0.000000 | ✓ no |
| bge-small-en-v1.5 | python | mlx-swift | 1.000000 | 1.000000 | 1.000000 | 0.000000 | ✓ no |
| bge-small-en-v1.5 | coreml | mlx-swift | 1.000000 | 1.000000 | 1.000000 | 0.000000 | ✓ no |

## Stability by Variant Type

| Variant Type | Mean | Std | Min | Max | Best Model | Worst Model |
|-------------|------|-----|-----|-----|------------|-------------|
| asr | 0.9091 | 0.0465 | 0.8053 | 0.9719 | multilingual-e5-small (python) | all-MiniLM-L6-v2 (python) |
| typo | 0.8247 | 0.1034 | 0.5665 | 0.9521 | multilingual-e5-small (python) | all-MiniLM-L6-v2 (python) |
| hesitation | 0.9266 | 0.0238 | 0.8852 | 0.9637 | multilingual-e5-small (python) | all-MiniLM-L6-v2 (python) |
| filler | 0.8991 | 0.0309 | 0.8280 | 0.9361 | multilingual-e5-small (python) | all-MiniLM-L6-v2 (python) |
| punctuation | 0.9479 | 0.0189 | 0.8940 | 0.9612 | mxbai-embed-large-v1 (python) | all-MiniLM-L6-v2 (python) |
| capitalization | 0.9837 | 0.0206 | 0.9430 | 1.0000 | nomic-embed-text-v1.5 (python) | Qwen3-Embedding-0.6B (python) |
| no_punctuation | 1.0000 | 0.0000 | 1.0000 | 1.0000 | multilingual-e5-base (python) | Qwen3-Embedding-0.6B (python) |
| doubled_word | 0.9741 | 0.0141 | 0.9349 | 0.9873 | snowflake-arctic-embed (python) | Qwen3-Embedding-0.6B (python) |

## Cluster Analysis

**Clusters:** 3
**Features:** quality_score, stability_mean, cold_load_time, embeddings_per_second, peak_rss_mb

### Cluster 2
- all-MiniLM-L6-v2 (python)
- bge-small-en-v1.5 (python)
- bge-base-en-v1.5 (python)
- multilingual-e5-base (python)
- multilingual-e5-small (python)
- nomic-embed-text-v1.5 (python)

### Cluster 0
- mxbai-embed-large-v1 (python)
- snowflake-arctic-embed (python)
- Qwen3-Embedding-0.6B (python)
- bge-m3 (python)
- multilingual-e5-large (python)

### Cluster 1
- all-MiniLM-L6-v2 (mlx-swift)
- bge-small-en-v1.5 (coreml)
- bge-small-en-v1.5 (mlx-swift)

## Dominance Relationships

- **bge-small-en-v1.5 (python)** dominates nomic-embed-text-v1.5 (python)
- **bge-base-en-v1.5 (python)** dominates nomic-embed-text-v1.5 (python)
- **multilingual-e5-base (python)** dominates nomic-embed-text-v1.5 (python)
- **multilingual-e5-small (python)** dominates nomic-embed-text-v1.5 (python)
- **mxbai-embed-large-v1 (python)** dominates nomic-embed-text-v1.5 (python)
- **snowflake-arctic-embed (python)** dominates nomic-embed-text-v1.5 (python)
- **all-MiniLM-L6-v2 (mlx-swift)** dominates bge-small-en-v1.5 (coreml)
- **all-MiniLM-L6-v2 (mlx-swift)** dominates bge-small-en-v1.5 (mlx-swift)
