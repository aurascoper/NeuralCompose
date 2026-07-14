# NeuralCompose Embedding Benchmark Summary

**Generated:** 2026-07-14T12:11:49.425221+00:00
**Total evaluations:** 14

## Evaluations by Runtime

- **coreml**: 1 models
- **mlx-swift**: 2 models
- **python**: 11 models

## Recommendations

### Best Overall (weighted score)
**all-MiniLM-L6-v2** (python) — score: 0.855

### Highest Quality
**all-MiniLM-L6-v2** (python) — quality: 0.7336

### Best Robustness to ASR Noise
**multilingual-e5-small** (python) — stability: 0.9693

### Fastest (cold load)
**all-MiniLM-L6-v2** (mlx-swift) — load: 0.03s

### Highest Throughput
**all-MiniLM-L6-v2** (python) — 1015 emb/s

### Lowest Memory
**bge-small-en-v1.5** (coreml) — RSS: 282MB

### Best Multilingual
**bge-m3** (python) — quality: 0.6526

### Best PYTHON
**all-MiniLM-L6-v2** — score: 0.855

### Best COREML
**bge-small-en-v1.5** — score: 0.200

### Pareto-Optimal Candidates

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

## Tradeoffs

NeuralCompose's primary use case is EEG-driven communication, where:
- **Latency** is the binding constraint (real-time interaction)
- **ASR robustness** is critical (input comes from speech recognition)
- **Memory** must fit alongside the MLX LLM in 16GB
- **Quality** matters for retrieval and replay accuracy

The weighted score reflects these priorities:
- Stability (ASR robustness): 0.2
- Quality: 0.25
- Latency: 0.15
- Throughput: 0.05
- Memory: 0.05
- Consistency: 0.05

Review the Pareto frontier to identify candidates that are not dominated
on any single objective — these are the models worth keeping on disk.
