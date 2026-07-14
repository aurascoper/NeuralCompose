# Statistical Analysis of Generation Benchmark

**Generated:** 2026-07-14T12:12:12.869734+00:00
**Git commit:** 377d6738af33a9fa34ab28e6edddd3d0561ee45c

## Sample Size Disclosure

- Evaluated candidates: **2**
- Total prompts per candidate: **27**
- Rewrite-shaped prompts (with cosine): **22**

**Note:** 27 prompts is a limited sample. Confidence intervals are wide and effect size estimates should be treated as preliminary. A larger prompt corpus (≥50 prompts) would increase statistical power.

## Rankings

### Latency

1. qwen-0.5b
2. gemma-3n-e2b

### Throughput

1. qwen-0.5b
2. gemma-3n-e2b

### Meaning Preservation

1. gemma-3n-e2b
2. qwen-0.5b

### Conciseness

1. qwen-0.5b
2. gemma-3n-e2b

### Stability

1. qwen-0.5b
2. gemma-3n-e2b

### First Token Latency

1. qwen-0.5b
2. gemma-3n-e2b

## Confidence Intervals (95% Bootstrap)

### Generate Time (seconds)

| Candidate | Mean | CI Low | CI High | n |
|-----------|------|--------|---------|---|
| qwen-0.5b | 1.148 | 0.778 | 1.543 | 27 |
| gemma-3n-e2b | 12.766 | 10.863 | 14.483 | 27 |

### Tokens per Second

| Candidate | Mean | CI Low | CI High | n |
|-----------|------|--------|---------|---|
| qwen-0.5b | 40.9 | 39.9 | 41.9 | 27 |
| gemma-3n-e2b | 7.2 | 7.1 | 7.3 | 27 |

### Meaning Preservation Cosine

| Candidate | Mean | CI Low | CI High | n |
|-----------|------|--------|---------|---|
| qwen-0.5b | 0.7436 | 0.6895 | 0.7944 | 22 |
| gemma-3n-e2b | 0.7713 | 0.7368 | 0.8042 | 22 |

## Pairwise Statistical Tests

### Mann-Whitney U (non-parametric, no normality assumption)

| Pair | Metric | U | p-value | p (Bonf.) | Effect r |
|------|--------|---|---------|-----------|----------|
| qwen-0.5b_vs_gemma-3n-e2b | generate_time | 37 | 0.0000 | 0.0000 | 0.948 |
| qwen-0.5b_vs_gemma-3n-e2b | tokens_per_second | 729 | 0.0000 | 0.0000 | -0.019 |
| qwen-0.5b_vs_gemma-3n-e2b | word_count_ratio | 261 | 0.0748 | 0.2243 | 0.635 |

### Effect Sizes (Cohen's d)

| Pair | Metric | Cohen's d | Interpretation |
|------|--------|-----------|----------------|
| qwen-0.5b_vs_gemma-3n-e2b | generate_time | -3.259 | large |
| qwen-0.5b_vs_gemma-3n-e2b | tokens_per_second | 17.713 | large |
| qwen-0.5b_vs_gemma-3n-e2b | word_count_ratio | -0.473 | small |

## Pareto Frontier

Pareto-optimal candidates (not dominated on both latency and quality):

- **qwen-0.5b**
- **gemma-3n-e2b**

## Cluster Analysis

K-means clustering (2 clusters) on standardized metrics (generate time, tokens/sec, word count ratio, cosine, maxTokens rate):

### Cluster 0
- qwen-0.5b

### Cluster 1
- gemma-3n-e2b

## Tradeoff Analysis

### Quality Vs Latency

- Insufficient data (n=2); need ≥3 for correlation

## Failure Mode Analysis

| Candidate | maxTokens Rate | Decoder Loop Rate | Echo Rate |
|-----------|---------------|-------------------|-----------|
| qwen-0.5b | 0.0% | 0.0% | 0.0% |
| gemma-3n-e2b | 0.0% | 0.0% | 0.0% |

## Threats to Validity

1. **Sample size:** With n=27 prompts, statistical power is limited. Bootstrap CIs are used because they don't require normality, but intervals are necessarily wide.
2. **Single device:** All measurements are from a single M4 Mac. Results may not generalize to other Apple Silicon variants.
3. **Single run:** No repeated measures (same prompt run multiple times). Variance estimates reflect between-prompt variance, not within-prompt noise.
4. **Prompt corpus bias:** The 26-prompt corpus may not represent the full distribution of user inputs in an EEG communication context.
5. **Temperature=0.7:** Results are at a single temperature. Lower temperatures may reduce variance but also reduce output diversity.
6. **maxTokens=120:** The generation cap truncates some outputs. maxTokens stop rate should be interpreted as a failure only if the model hasn't naturally concluded by then.
7. **Manual scoring pending:** Meaning preservation, grammar, instruction following, hallucination, and fluency scores are not yet available from manual review. The cosine similarity is a proxy for meaning preservation, not a direct quality measure.
