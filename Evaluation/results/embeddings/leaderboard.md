# NeuralCompose Embedding Benchmark Leaderboard

**Updated:** 2026-07-14T12:11:49.419356+00:00
**Candidates evaluated:** 14
**Score weights:** quality=0.25, stability=0.2, latency=0.15, throughput=0.05, memory=0.05, consistency=0.05

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

## Rankings

| Rank | Model | Runtime | Score | Stability | Quality | Latency (s) | emb/s | RSS (MB) | Dim | Size (MB) | Pareto |
|------|-------|---------|-------|-----------|---------|-------------|-------|----------|-----|-----------|--------|
| 1 | all-MiniLM-L6-v2 | python | 0.855 | 0.8680 | 0.7336 | 7.57 | 1015 | 506 | 384 | 932 | ★ |
| 2 | bge-small-en-v1.5 | python | 0.830 | 0.9408 | 0.6467 | 7.32 | 557 | 550 | 384 | 383 | ★ |
| 3 | bge-base-en-v1.5 | python | 0.830 | 0.9298 | 0.6444 | 6.26 | 511 | 780 | 768 | 1252 | ★ |
| 4 | multilingual-e5-base | python | 0.788 | 0.9602 | 0.6492 | 8.26 | 498 | 1170 | 768 | 5076 | ★ |
| 5 | multilingual-e5-small | python | 0.784 | 0.9693 | 0.6503 | 9.13 | 526 | 1037 | 384 | 2175 | ★ |
| 6 | mxbai-embed-large-v1 | python | 0.774 | 0.9285 | 0.6512 | 8.14 | 25 | 979 | 1024 | 5111 | ★ |
| 7 | snowflake-arctic-embed | python | 0.772 | 0.9525 | 0.6417 | 6.53 | 170 | 1597 | 1024 | 4740 | ★ |
| 8 | Qwen3-Embedding-0.6B | python | 0.768 | 0.9128 | 0.6469 | 6.35 | 11 | 1439 | 1024 | 1152 | ★ |
| 9 | nomic-embed-text-v1.5 | python | 0.755 | 0.9269 | 0.6373 | 11.31 | 429 | 899 | 768 | 2113 |  |
| 10 | bge-m3 | python | 0.749 | 0.9213 | 0.6526 | 8.10 | 157 | 2136 | 1024 | 4375 | ★ |
| 11 | multilingual-e5-large | python | 0.743 | 0.9545 | 0.6496 | 8.13 | 172 | 2091 | 1024 | 9115 | ★ |
| 12 | all-MiniLM-L6-v2 | mlx-swift | 0.202 | 0.0000 | 0.1000 | 0.03 | 134 | 447 | 384 | 0 | ★ |
| 13 | bge-small-en-v1.5 | coreml | 0.200 | 0.0000 | 0.1000 | 0.08 | 16 | 282 | 384 | 0 |  |
| 14 | bge-small-en-v1.5 | mlx-swift | 0.199 | 0.0000 | 0.1000 | 0.03 | 73 | 440 | 384 | 0 |  |

## Metric Definitions

- **Score**: weighted sum of min-max normalized metrics across all evaluated candidates
- **Stability**: mean cosine similarity between original and ASR/typo/hesitation/filler/punctuation/capitalization variants
- **Quality**: composite of paraphrase similarity, retrieval accuracy, command-group separation, antonym discrimination
- **Latency**: cold load time in seconds (lower is better)
- **emb/s**: embeddings per second at batch size 128 (higher is better)
- **RSS**: peak resident set size in MB (lower is better)
- **Dim**: embedding dimensionality
- **Size**: model size on disk in MB
- **Pareto**: ★ = not dominated on quality, stability, and latency

## Stability by Variant Type

| Model | Runtime | ASR | Typo | Hesitation | Filler | Punctuation | Capitalization | No-Punct | Doubled |
|-------|---------|-----|------|------------|--------|-------------|----------------|----------|---------|
| all-MiniLM-L6-v2 | python | 0.8053 | 0.5665 | 0.8852 | 0.8280 | 0.8940 | 1.0000 | 1.0000 | 0.9653 |
| bge-small-en-v1.5 | python | 0.9103 | 0.8285 | 0.9419 | 0.9085 | 0.9514 | 1.0000 | 1.0000 | 0.9861 |
| bge-base-en-v1.5 | python | 0.8998 | 0.8030 | 0.9175 | 0.8915 | 0.9520 | 1.0000 | 1.0000 | 0.9750 |
| multilingual-e5-base | python | 0.9652 | 0.9319 | 0.9467 | 0.9223 | 0.9607 | 0.9747 | 1.0000 | 0.9804 |
| multilingual-e5-small | python | 0.9719 | 0.9521 | 0.9637 | 0.9361 | 0.9609 | 0.9831 | 1.0000 | 0.9864 |
| mxbai-embed-large-v1 | python | 0.8848 | 0.7792 | 0.9181 | 0.9048 | 0.9612 | 1.0000 | 1.0000 | 0.9796 |
| snowflake-arctic-embed | python | 0.9291 | 0.8777 | 0.9353 | 0.9318 | 0.9589 | 1.0000 | 1.0000 | 0.9873 |
| Qwen3-Embedding-0.6B | python | 0.8846 | 0.8331 | 0.8877 | 0.8699 | 0.9490 | 0.9430 | 1.0000 | 0.9349 |
| nomic-embed-text-v1.5 | python | 0.8709 | 0.7452 | 0.9450 | 0.9184 | 0.9576 | 1.0000 | 1.0000 | 0.9779 |
| bge-m3 | python | 0.9168 | 0.8232 | 0.9115 | 0.8685 | 0.9313 | 0.9498 | 1.0000 | 0.9694 |
| multilingual-e5-large | python | 0.9614 | 0.9315 | 0.9401 | 0.9106 | 0.9496 | 0.9702 | 1.0000 | 0.9729 |
| all-MiniLM-L6-v2 | mlx-swift | 0.0000 | 0.0000 | 0.0000 | 0.0000 | 0.0000 | 0.0000 | 0.0000 | 0.0000 |
| bge-small-en-v1.5 | coreml | 0.0000 | 0.0000 | 0.0000 | 0.0000 | 0.0000 | 0.0000 | 0.0000 | 0.0000 |
| bge-small-en-v1.5 | mlx-swift | 0.0000 | 0.0000 | 0.0000 | 0.0000 | 0.0000 | 0.0000 | 0.0000 | 0.0000 |
