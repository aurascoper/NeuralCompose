# Generation Benchmark Summary

**Schema version:** 1
**Git commit:** 377d6738af33a9fa34ab28e6edddd3d0561ee45c
**Device:** Apple M4
**macOS:** 26.5.2

## Overview

| Candidate | Cold Load (s) | Warm Load (s) | Peak RSS (MB) | Prompts |
|-----------|--------------|--------------|---------------|---------|
| qwen-0.5b | 2.64 | 2.51 | 708 | 27 |
| gemma-3n-e2b | 11.77 | 11.96 | 858 | 27 |

## Latency

| Candidate | First Token (ms) | Generate (s) | Generate CI95 |
|-----------|-----------------|-------------|---------------|
| qwen-0.5b | 24.4 ± 3.1 | 1.15 ± 1.03 | [0.78, 1.54] |
| gemma-3n-e2b | 155.3 ± 26.0 | 12.77 ± 4.94 | [10.86, 14.48] |

## Throughput

| Candidate | tok/s | tok/s CI95 | words/s |
|-----------|-------|------------|---------|
| qwen-0.5b | 40.9 ± 2.7 | [39.9, 41.9] | 0.0 |
| gemma-3n-e2b | 7.2 ± 0.3 | [7.1, 7.3] | 0.0 |

## Quality

| Candidate | Meaning Cosine | Cosine CI95 | n_cosine |
|-----------|---------------|------------|----------|
| qwen-0.5b | 0.7436 ± 0.1293 | [0.6895, 0.7944] | 22 |
| gemma-3n-e2b | 0.7713 ± 0.0831 | [0.7368, 0.8042] | 22 |

## Failure Modes

| Candidate | maxTokens Rate | EOS Rate | Decoder Loop Rate | Echo Rate |
|-----------|---------------|----------|-------------------|-----------|
| qwen-0.5b | 0.0% | 0.0% | 0.0% | 0.0% |
| gemma-3n-e2b | 0.0% | 0.0% | 0.0% | 0.0% |

## Verbosity

| Candidate | Word Count Ratio | WC Ratio CI95 |
|-----------|-----------------|---------------|
| qwen-0.5b | 3.32 ± 3.23 | [2.16, 4.55] |
| gemma-3n-e2b | 4.62 ± 2.20 | [3.79, 5.45] |

## Per-Category Breakdown

### qwen-0.5b

| Category | n | Gen Time (s) | tok/s | WC Ratio | Cosine |
|----------|---|-------------|-------|----------|--------|
| capitalization | 3 | 2.36 | 41.0 | 7.47 | 0.7799 |
| command-reformulation | 4 | 0.22 | 38.0 | 0.57 | 0.7926 |
| concise-rewrite | 4 | 0.88 | 40.6 | 1.75 | 0.7501 |
| filler-removal | 4 | 1.75 | 41.5 | 4.86 | 0.5559 |
| instruction-following | 5 | 0.45 | 44.3 | 2.45 | — |
| punctuation-restoration | 4 | 2.28 | 41.6 | 6.14 | 0.7737 |
| technical-term-preservation | 3 | 0.39 | 37.9 | 0.54 | 0.8436 |

### gemma-3n-e2b

| Category | n | Gen Time (s) | tok/s | WC Ratio | Cosine |
|----------|---|-------------|-------|----------|--------|
| capitalization | 3 | 16.47 | 7.2 | 7.83 | 0.7964 |
| command-reformulation | 4 | 11.41 | 7.1 | 4.77 | 0.8060 |
| concise-rewrite | 4 | 16.54 | 7.1 | 4.65 | 0.7386 |
| filler-removal | 4 | 14.72 | 7.4 | 5.72 | 0.6528 |
| instruction-following | 5 | 7.32 | 7.4 | 2.82 | — |
| punctuation-restoration | 4 | 11.07 | 7.2 | 4.21 | 0.7924 |
| technical-term-preservation | 3 | 14.58 | 6.9 | 3.27 | 0.8737 |
