# NeuralCompose Generation Benchmark Leaderboard

**Updated:** 2026-07-14T11:50:59.528865+00:00
**Candidates evaluated:** 16
**Score weights:** quality=0.35, latency=0.3, throughput=0.15, memory=0.1, stability=0.05, instruction_following=0.05

## Pareto Frontier

- **tinyllama-1.1b**
- **qwen2.5-0.5b**
- **smollm2-360m**
- **qwen2.5-3b**

## Rankings

| Rank | Candidate | Score | Latency (s) | tok/s | RSS (MB) | Cosine | Stability | Instr. Follow | Pareto |
|------|-----------|-------|------------|-------|----------|--------|-----------|---------------|--------|
| 1 | tinyllama-1.1b | 0.843 | 1.27 | 42.1 | 1455 | 0.7484 | 0.95 | 0.80 | ★ |
| 2 | qwen2.5-0.5b | 0.801 | 1.23 | 37.5 | 707 | 0.7307 | 0.96 | 0.60 | ★ |
| 3 | smollm2-360m | 0.784 | 1.22 | 40.0 | 668 | 0.7207 | 0.99 | 0.40 | ★ |
| 4 | llama-3.2-3b | 0.777 | 2.23 | 22.5 | 378 | 0.7593 | 0.96 | 0.60 |  |
| 5 | qwen2.5-3b | 0.763 | 2.20 | 20.7 | 3480 | 0.7940 | 0.98 | 0.80 | ★ |
| 6 | smollm2-1.7b | 0.756 | 2.44 | 13.9 | 419 | 0.7685 | 0.99 | 0.60 |  |
| 7 | gemma-3-1b | 0.756 | 2.82 | 22.6 | 1821 | 0.7906 | 0.98 | 0.00 |  |
| 8 | llama-3.2-1b | 0.707 | 2.50 | 35.2 | 1561 | 0.7412 | 0.90 | 0.00 |  |
| 9 | qwen2.5-1.5b | 0.694 | 1.69 | 27.0 | 1834 | 0.7267 | 0.95 | 0.60 |  |
| 10 | qwen3-1.7b | 0.685 | 3.92 | 30.6 | 2051 | 0.7837 | 0.67 | 0.00 |  |
| 11 | phi-3.5-mini | 0.591 | 3.82 | 17.6 | 250 | 0.7137 | 0.93 | 0.40 |  |
| 12 | qwen3-4b | 0.548 | 7.71 | 15.6 | 1115 | 0.7928 | 0.67 | 0.00 |  |
| 13 | openelm-1.1b | 0.479 | 3.29 | 36.5 | 1252 | 0.6376 | 0.67 | 1.00 |  |
| 14 | phi-4-mini | 0.426 | 5.04 | 15.8 | 772 | 0.6698 | 0.90 | 0.40 |  |
| 15 | gemma-3n-e4b | 0.424 | 10.43 | 7.8 | 1037 | 0.7656 | 0.89 | 0.40 |  |
| 16 | gemma-3n-e2b | 0.420 | 10.65 | 8.4 | 1145 | 0.7692 | 0.86 | 0.40 |  |

## Metric Definitions

- **Score**: weighted sum of min-max normalized metrics across all evaluated candidates
- **Latency**: mean generation time in seconds (lower is better)
- **tok/s**: mean tokens per second (higher is better)
- **RSS**: peak resident set size in MB (lower is better)
- **Cosine**: mean meaning-preservation cosine similarity (higher is better, rewrite prompts only)
- **Stability**: 1 - (maxTokens_rate + decoder_loop_rate + echo_rate) / 3
- **Instr. Follow**: fraction of instruction-following prompts with word_count_ratio < 2.0
- **Pareto**: ★ = not dominated on both latency and quality
