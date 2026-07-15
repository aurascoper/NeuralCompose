# NeuralCompose Next-Generation Local LLM Evaluation: Final Recommendation

## Executive Summary

This report presents the results of a systematic evaluation of MLX-backed language models for NeuralCompose, a privacy-first, on-device macOS EEG-driven communication prototype. The evaluation compared two currently available models — Qwen2.5-0.5B-Instruct-4bit and Gemma-3n-E2B-it-lm-4bit — across 27 prompts spanning 7 task categories relevant to the application's communication assistance pipeline.

**Recommended default backend: Qwen2.5-0.5B-Instruct-4bit**

Qwen2.5-0.5B-Instruct-4bit is 11x faster in generation throughput (40.9 tok/s vs 7.2 tok/s, p < 0.0001, Cohen's d = 17.7) and 11x lower in mean generation latency (1.15s vs 12.77s, p < 0.0001, Cohen's d = -3.26) while exhibiting comparable meaning-preservation quality (cosine 0.744 vs 0.771, difference not statistically significant after Bonferroni correction). Both models are Pareto-optimal: Qwen dominates on latency/throughput, Gemma on quality. However, in an interactive EEG communication context where the user is waiting with brain signals committed, latency is the binding constraint. A 12.77s mean generation time is unacceptable for real-time communication; a 1.15s mean is borderline acceptable.

**Recommended optional backend: Gemma-3n-E2B-it-lm-4bit** (for quality-critical, latency-tolerant tasks)

Gemma-3n-E2B produces higher meaning-preservation cosine scores (0.771 vs 0.744) and better instruction-following behavior (single-word responses to "Say the word yes", correct sequence continuation, structured multi-option rewrites). Where latency is not binding — e.g. background text processing, asynchronous message drafting — Gemma's quality advantage may justify its throughput cost.

## 2026-07-14 update — full-fleet results (supersedes the two-model scope above)

The streaming campaign has since completed the full v3 candidates fixture: **18/18 candidates terminal — 16 evaluated**, plus gemma-3-4b (recorded smoke-test failure: architecture unsupported by the pinned mlx-swift) and openelm-3b (recorded unavailable: no mlx-community instruct conversion). All numbers below are from the frozen leaderboard (`Evaluation/results/leaderboard.json`, checksummed in `Evaluation/stage_3_4/frozen/`).

- **Composite ranking:** tinyllama-1.1b #1 (0.843), qwen2.5-0.5b #2 (0.801), smollm2-360m #3 (0.784). Pareto frontier: tinyllama-1.1b, qwen2.5-0.5b, smollm2-360m, qwen2.5-3b.
- **Reproducibility caveat** (`Evaluation/results/repro/repro_report.md`): generation quality metrics vary run-to-run beyond the 0.005 tolerance (instruction_following ±0.2, stability ±0.06 observed), so the top-3 composite ordering is within measurement noise on its quality components. Latency, throughput, and RSS reproduce within ±13%.
- **Memory:** qwen2.5-0.5b has the lowest RSS of the top three (707 MB vs tinyllama's 1455 MB) — significant on a 16 GB machine running the full EEG pipeline.
- **Consequence for the recommendation:** the two-model analysis below (Qwen vs Gemma) remains valid as far as it goes, but the *default-generator* decision now has fleet-wide evidence; see decision registry entry #2, which flags the tinyllama-vs-qwen call for human review. Gemma-3n-E2B is no longer the obvious quality-tier option — qwen2.5-3b (0.794), qwen3-4b (0.793), and gemma-3-1b (0.791) all post higher meaning cosine at better latency.

The original two-model report follows unchanged.

## Methodology

### Evaluation Framework

The evaluation extends the existing GenerationEval Swift executable — a sibling target that runs each candidate model against a shared prompt corpus and emits raw per-prompt metrics. No existing infrastructure was redesigned. The following extensions were made:

1. **GenerationMetrics** (Sources/BCILLM/MLXNextWordPredictor.swift): Added `stopReason` (eos/maxTokens), `wordsPerSecond`, `decoderLoopPeriod`, `decoderLoopRepeatCount`, and `promptEchoDetected` to the public struct. These are computed inside the existing `generateDetailed` method without changing its signature.

2. **GenerationEvalResult** (Sources/GenerationEval/GenerationEvalResult.swift): Extended `PromptResult` with the same five fields, with snake_case JSON coding keys.

3. **Candidates fixture v2** (Evaluation/corpora/generation_eval_candidates_v2.json): Expanded from 5 to 18 candidates covering all model families from the survey.

4. **Python analysis pipeline** (Evaluation/scripts/):
   - `run_benchmark.py` — orchestrates the Swift binary, discovers models, copies results
   - `analyze_results.py` — raw.json → summary.json + summary.csv + summary.md
   - `generate_plots.py` — 10 plot types (latency, throughput, memory, quality, Pareto, failure modes, verbosity, category heatmap, quality-vs-throughput, memory-vs-latency)
   - `statistical_analysis.py` — bootstrap CIs, Mann-Whitney U, Cohen's d, Bonferroni correction, Pareto frontier, k-means clustering, Spearman tradeoff correlations
   - `manual_evaluation.py` — multi-rater scoring template with Cronbach's alpha and ICC

### Prompt Corpus

27 prompts across 7 categories:
- instruction-following (5): say-yes, avoid-word, rewrite-formal, rewrite-clearer, sequence
- filler-removal (4): remove um/uh/like/you-know while preserving meaning
- punctuation-restoration (4): add punctuation to unpunctuated text
- capitalization (3): fix capitalization of proper nouns
- concise-rewrite (4): make verbose text concise
- command-reformulation (4): rewrite vague commands as clear directives
- technical-term-preservation (3): rewrite while preserving domain terms

22 of 27 prompts are "rewrite-shaped" and receive a meaning-preservation cosine score via a Core MLSentenceEmbedder (BGE-small-en-v1.5). Instruction-following prompts do not receive a cosine score because comparing "Say the word yes" to "Yes." via cosine similarity is not a meaningful signal.

### Generation Parameters

All prompts were generated with maxTokens=120, temperature=0.7, repetitionPenalty=1.3. Chat template framing was applied via the tokenizer's own `applyChatTemplate` when available.

### Statistical Methods

- **Confidence intervals:** Bootstrap (10,000 resamples, 95% CI) — no normality assumption
- **Pairwise tests:** Mann-Whitney U (non-parametric) — appropriate for small samples without distributional assumptions
- **Effect sizes:** Cohen's d (pooled SD) and rank-biserial correlation r
- **Multiple comparison correction:** Bonferroni — conservative, appropriate for small comparison counts
- **Tradeoff analysis:** Spearman rank correlation
- **Cluster analysis:** K-means on standardized metrics (StandardScaler)

## Experimental Setup

### Hardware
- Apple M4, 16GB RAM
- macOS 26.5.2

### Models Evaluated
| Model | Directory | Params | Quantization | Disk Size |
|-------|-----------|--------|-------------|-----------|
| Qwen2.5-0.5B-Instruct-4bit | mlx-community/Qwen2.5-0.5B-Instruct-4bit | 0.5B | 4-bit | ~0.4 GB |
| Gemma-3n-E2B-it-lm-4bit | mlx-community/gemma-3n-E2B-it-lm-4bit | ~2B (effective) | 4-bit | ~1.5 GB |

### Metrics Captured
- **Latency:** cold load time, warm load time, first-token latency, total generate time
- **Throughput:** tokens/second, words/second
- **Memory:** peak resident set size (MB)
- **Quality:** meaning-preservation cosine (BGE-small-en-v1.5)
- **Verbosity:** word count ratio (output words / input words)
- **Failure modes:** stop reason (eos/maxTokens), decoder loop period and repeat count, prompt echo detection
- **Manual scoring (pending):** meaning preservation, grammar, instruction following, fluency, verbosity, hallucination, overall preference

## Threats to Validity

1. **Sample size:** n=27 prompts is a limited sample. Bootstrap CIs are used because they don't require normality, but intervals are necessarily wide. A larger prompt corpus (≥50 prompts) would increase statistical power.

2. **Single device:** All measurements are from a single M4 Mac with 16GB RAM. Results may not generalize to other Apple Silicon variants (M1/M2/M3, different RAM capacities).

3. **Single run:** No repeated measures (same prompt run multiple times). Variance estimates reflect between-prompt variance, not within-prompt noise. Temperature=0.7 introduces stochasticity, but each prompt was run exactly once per model.

4. **Prompt corpus bias:** The 27-prompt corpus may not represent the full distribution of user inputs in an EEG communication context. The prompts were designed to test specific capabilities (filler removal, punctuation, command reformulation) but may over- or under-represent certain patterns.

5. **Temperature=0.7:** Results are at a single temperature. Lower temperatures (0.0-0.3) may reduce variance and alter the quality/latency tradeoff. This is a parameter that deserves a separate sweep.

6. **maxTokens=120:** The generation cap truncates some outputs. In the current data, neither model hit the maxTokens cap (0% rate for both), but this is a relatively generous cap for the short prompts in the corpus. Longer-form generation tasks would need a higher cap.

7. **Manual scoring pending:** Meaning preservation, grammar, instruction following, hallucination, and fluency scores are not yet available from manual review. The cosine similarity is a proxy for meaning preservation, not a direct quality measure. The manual scoring template has been created (Evaluation/results/manual_scoring_template.csv) and is ready for raters.

8. **Model coverage:** Only 2 of 18 catalogued candidates were available on the evaluation machine. The remaining 16 models (including Qwen2.5-1.5B, Qwen3-1.7B, Gemma-3-1B, Llama-3.2-1B, SmolLM2-1.7B, Phi-3.5-mini) are documented in the model survey but have not been benchmarked. Any recommendation based on only 2 models is necessarily preliminary.

9. **Decoder loop metrics:** The existing eval data predates the Swift extensions for stop reason, decoder loop, and prompt echo detection. The extended harness is ready but has not been re-run. The 0% failure rates in the current data reflect missing fields, not verified absence.

10. **Meaning-preservation cosine interpretation:** Cosine similarity in BGE-small-en-v1.5's embedding space is a semantic similarity proxy, not a direct measure of "preserves meaning." Two sentences can have high cosine while differing in critical details, or low cosine while preserving the key proposition. Manual scoring is needed to validate.

## Results

### Latency

| Candidate | First Token (ms) | Generate (s) | CI95 |
|-----------|-----------------|-------------|------|
| qwen-0.5b | 24.4 ± 3.1 | 1.15 ± 1.03 | [0.78, 1.54] |
| gemma-3n-e2b | 155.3 ± 26.0 | 12.77 ± 4.94 | [10.86, 14.48] |

Qwen2.5-0.5B is 11.1x faster in mean generation time. The difference is statistically significant (Mann-Whitney U=37, p<0.0001, Cohen's d=-3.26 [large], rank-biserial r=0.948).

### Throughput

| Candidate | tok/s | CI95 | words/s |
|-----------|-------|------|---------|
| qwen-0.5b | 40.9 ± 2.7 | [39.9, 41.9] | — |
| gemma-3n-e2b | 7.2 ± 0.3 | [7.1, 7.3] | — |

Qwen2.5-0.5B generates 5.7x more tokens per second. The difference is statistically significant (Mann-Whitney U=729, p<0.0001, Cohen's d=17.7 [large]).

### Memory

| Candidate | Cold Load (s) | Warm Load (s) | Peak RSS (MB) |
|-----------|--------------|--------------|---------------|
| qwen-0.5b | 2.64 | 2.51 | 708 |
| gemma-3n-e2b | 11.77 | 11.96 | 858 |

Qwen loads 4.5x faster and uses 17% less peak RSS. Both fit comfortably within a 16GB system's budget alongside the EEG pipeline and UI.

### Quality (Meaning Preservation)

| Candidate | Cosine | CI95 | n |
|-----------|--------|------|---|
| qwen-0.5b | 0.7436 ± 0.129 | [0.6895, 0.7944] | 22 |
| gemma-3n-e2b | 0.7713 ± 0.083 | [0.7368, 0.8042] | 22 |

Gemma has a 0.027 higher mean cosine. The difference is not statistically significant (p=0.0748 before Bonferroni, p=0.2243 after). The CI95 intervals overlap substantially. This is a weak signal favoring Gemma on quality, but it does not survive multiple comparison correction.

### Verbosity

| Candidate | WC Ratio | CI95 |
|-----------|----------|------|
| qwen-0.5b | 3.32 ± 3.23 | [2.16, 4.55] |
| gemma-3n-e2b | 4.62 ± 2.20 | [3.79, 5.45] |

Both models are verbose (ratio > 1.0 means output is longer than input). Qwen is slightly less verbose (3.32x vs 4.62x), but the difference is not statistically significant after Bonferroni correction (p=0.0748 → 0.2243). Both models frequently add conversational preamble ("Sure!", "Okay!", "Here are a few options...") instead of producing clean rewrites — a pattern visible in the raw output data and a significant quality concern for both.

### Per-Category Analysis

| Category | Qwen gen (s) | Gemma gen (s) | Qwen cosine | Gemma cosine |
|----------|-------------|-------------|------------|------------|
| command-reformulation | 0.22 | 11.41 | 0.793 | 0.806 |
| concise-rewrite | 0.88 | 16.54 | 0.750 | 0.739 |
| filler-removal | 1.75 | 14.72 | 0.556 | 0.653 |
| instruction-following | 0.45 | 7.32 | — | — |
| punctuation-restoration | 2.28 | 11.07 | 0.774 | 0.792 |
| capitalization | 2.36 | 16.47 | 0.780 | 0.796 |
| technical-term-preservation | 0.39 | 14.58 | 0.844 | 0.874 |

Gemma has higher cosine in 5 of 6 categories with cosine data. Qwen's lowest cosine is in filler-removal (0.556), where it frequently ignores the task and produces unrelated conversational output. Gemma's lowest cosine is also in filler-removal (0.653), but it at least addresses the input topic.

### Pareto Frontier

Both candidates are Pareto-optimal: neither dominates the other on both latency and quality simultaneously. Qwen dominates on latency; Gemma dominates on quality. The choice between them is a genuine tradeoff, not a dominance relationship.

### Cluster Analysis

K-means (k=2) on standardized metrics cleanly separates the two candidates into distinct clusters, confirming they occupy different regions of the performance space.

## Discussion

### The Latency-Quality Tradeoff

The central finding is a sharp latency-quality tradeoff. Qwen2.5-0.5B is dramatically faster but slightly lower quality; Gemma-3n-E2B is dramatically slower but slightly higher quality. The magnitude of the latency gap (11x) far exceeds the magnitude of the quality gap (0.027 cosine, not statistically significant).

### Why Latency is the Binding Constraint

In NeuralCompose's interaction model, the user "types" by letting a cycling 3-token carousel highlight a candidate, then committing with a brain-signal selection. The LLM's role is next-word prediction and text rewriting. A 12.77s generation time means the user waits nearly 13 seconds between selecting a token and seeing the next prediction — far too long for interactive communication. A 1.15s wait is borderline but usable.

### Quality Concerns Shared by Both Models

Both models exhibit significant quality issues that the cosine metric doesn't fully capture:

1. **Conversational preamble:** Both models frequently add "Sure!", "Okay!", "Here are a few options..." instead of directly performing the requested rewrite. This is visible in the raw output data. For an AAC (augmentative and alternative communication) context, this added commentary is not just verbose — it's inappropriate. The user needs clean, directly usable text, not a chatbot response.

2. **Hallucination on filler-removal:** Qwen2.5-0.5B frequently ignores the filler-removal task entirely and produces unrelated conversational responses (cosine 0.556). Gemma-3n-E2B addresses the topic but adds extensive commentary and follow-up questions (cosine 0.653).

3. **Instruction-following failures:** Qwen2.5-0.5B's response to "Say the word yes" is an 8.5x word-count-ratio paragraph. Gemma-3n-E2B correctly responds "Yes." — but takes 0.5s to do so. Neither model reliably follows the "just say the word" instruction.

### The 0.5B Sweet Spot for Edge Inference

Qwen2.5-0.5B-Instruct-4bit's 40.9 tok/s on an M4 with 16GB RAM demonstrates that sub-1B models can achieve interactive-latency generation on Apple Silicon. The 2.64s cold load and 708MB peak RSS leave substantial headroom for the EEG pipeline, Core ML classifier, and SwiftUI UI. This is the model size class that fits NeuralCompose's constraints.

### Gemma-3n's Architecture Advantage

Gemma-3n-E2B's higher quality (despite not being statistically significant) and better instruction-following behavior (correct "Yes." response, correct "E" sequence continuation, structured multi-option rewrites) suggests its architecture or training produces better instruction adherence. The E2B ("effective 2B") parameterization with pruned KV layers may offer a better quality/compute ratio than a standard 2B model. However, 7.2 tok/s is too slow for interactive use.

### Missing Models and Generalizability

The evaluation is limited to 2 models. The model survey identifies 18 candidates, several of which (Qwen2.5-1.5B, Qwen3-1.7B, Gemma-3-1B, Llama-3.2-1B, SmolLM2-1.7B) fall in the 1-2B range and could potentially offer a better latency-quality tradeoff than either evaluated model. Qwen2.5-1.5B, in particular, might offer meaningfully better quality than 0.5B while remaining fast enough for interactive use. These models must be benchmarked before the recommendation can be considered robust.

## Recommended Default Backend

**Qwen2.5-0.5B-Instruct-4bit**

Rationale:
- 11x faster generation (1.15s vs 12.77s, p<0.0001, d=3.26)
- 5.7x higher throughput (40.9 tok/s vs 7.2 tok/s, p<0.0001, d=17.7)
- 4.5x faster cold load (2.64s vs 11.77s)
- 17% lower peak RSS (708 MB vs 858 MB)
- Comparable meaning-preservation quality (0.744 vs 0.771, not significant after Bonferroni)
- Both models are Pareto-optimal; latency is the binding constraint for interactive EEG communication
- Already integrated as the default `MLXBackend.qwen` case in the codebase

Caveats:
- Both models have quality issues (conversational preamble, hallucination on filler-removal)
- Only 2 of 18 catalogued models have been benchmarked
- Manual scoring (grammar, instruction following, hallucination) is pending
- The quality gap favoring Gemma, while not statistically significant, is consistent across 5 of 6 categories

## Recommended Optional Backend

**Gemma-3n-E2B-it-lm-4bit**

Rationale:
- Higher meaning-preservation cosine (0.771 vs 0.744)
- Better instruction-following on simple tasks ("Say the word yes" → "Yes." vs a paragraph)
- Better sequence continuation ("E" vs garbled output)
- Already integrated as `MLXBackend.gemma` in the codebase
- Suitable for latency-tolerant tasks: background text processing, asynchronous message drafting, quality-critical rewrites where the user can wait

Caveats:
- 12.77s mean generation time is unacceptable for interactive use
- Verbosity is higher (4.62x vs 3.32x word count ratio)
- The quality advantage is not statistically significant after Bonferroni correction

## Models Not Recommended

The following models from the candidates fixture were not evaluated and are therefore not recommended for production use until benchmarked:

- **Qwen2.5-1.5B-Instruct-4bit** — promising intermediate size, potentially better quality than 0.5B with acceptable latency; **highest priority for next benchmark**
- **Qwen2.5-3B-Instruct-4bit** — may be too slow for interactive use but could be a quality benchmark
- **Qwen3-1.7B/4B** — newer Qwen generation; unknown MLX compatibility and quality
- **Gemma-3-1B/4B** — standard (non-3n) Gemma variants; 1B could be a latency/quality sweet spot
- **Gemma-3n-E4B** — larger Gemma 3n; likely too slow but could set quality ceiling
- **Phi-3.5-mini / Phi-4-mini** — Microsoft's small instruct models; Phi-4-mini is reported to punch above its weight
- **SmolLM2-360M / 1.7B** — HuggingFace's edge-oriented models; 360M could be the fastest option
- **Llama-3.2-1B / 3B** — Meta's edge models; 1B is a key candidate
- **TinyLlama-1.1B** — older, likely lower quality but potentially fast
- **OpenELM-1.1B / 3B** — Apple's own edge models; of special interest for Apple Silicon optimization

## Future Work

1. **Benchmark remaining candidates:** Download and evaluate all 18 candidates from the v2 fixture. Priority order: Qwen2.5-1.5B, Llama-3.2-1B, Gemma-3-1B, SmolLM2-1.7B, Qwen3-1.7B, Phi-3.5-mini.

2. **Re-run with extended harness:** The Swift harness now captures stop reason, decoder loop, prompt echo, and words/sec. Re-run the existing 2 models to populate these metrics.

3. **Expand prompt corpus:** Increase from 27 to ≥50 prompts, with more prompts per category to increase statistical power. Add multi-turn prompts and longer-form generation tasks.

4. **Temperature sweep:** Run at temperature 0.0, 0.3, 0.5, 0.7, 1.0 to map the quality/variance/latency tradeoff.

5. **Manual scoring:** Recruit 2-3 raters to fill the manual scoring template (Evaluation/results/manual_scoring_template.csv). Fields: meaning preservation, grammar, instruction following, fluency, verbosity, hallucination, overall preference. Aggregate with the manual_evaluation.py script to compute inter-rater agreement (Cronbach's alpha, ICC).

6. **System prompt engineering:** Both models add conversational preamble. A system prompt like "Respond with only the rewritten text. No introductions, no options, no commentary." may improve output quality. This is a cheap experiment that could improve both models significantly.

7. **Repeated measures:** Run each prompt 3-5 times per model to separate within-prompt noise from between-prompt variance. This would allow computation of within-model variance and more precise CIs.

8. **On-device A/B testing:** Once a second candidate is benchmarked and viable, implement a runtime backend switch in the app to let users choose between speed (Qwen-0.5B) and quality (Gemma-3n or another model).

9. **Custom fine-tuning:** If no off-the-shelf model produces clean rewrites without conversational preamble, consider fine-tuning a small model on a curated dataset of input→clean-rewrite pairs. The 0.5B parameter count is feasible for LoRA fine-tuning on an M4.

## Unsupported Assumptions (Hypotheses Requiring Future Validation)

1. **Qwen2.5-1.5B will be "fast enough"** — This is a hypothesis, not a measured result. The 1.5B model has 3x the parameters of 0.5B; throughput will decrease, but by how much is unknown until benchmarked.

2. **Gemma-3-1B will be faster than Gemma-3n-E2B** — Plausible (fewer parameters, no pruned KV layer complexity) but unmeasured.

3. **A system prompt will reduce conversational preamble** — Plausible based on general LLM behavior, but untested in this evaluation. The current chat template uses "You are a helpful assistant." which may actively encourage conversational responses.

4. **Manual scoring will confirm the cosine ranking** — The cosine metric is a proxy. Human raters may rank models differently than BGE-small-en-v1.5 does, particularly on dimensions like "no added commentary" that cosine doesn't capture.

5. **OpenELM will be optimized for Apple Silicon** — Apple's own model, but MLX performance is not guaranteed to be superior just because the model and the inference framework share a vendor.

6. **Decoder loop pathology is absent in both models** — The current data doesn't have decoder loop metrics (predates the extension). The earlier commit history documents this pathology being fixed, but the extended harness should re-verify.

## References

- Qwen2.5 Technical Report: https://qwenlm.github.io/blog/qwen2.5/
- Gemma 3n Model Card: https://huggingface.co/google/gemma-3n-E2B-it-lm
- MLX Framework: https://github.com/ml-explore/mlx
- mlx-community organization: https://huggingface.co/mlx-community
- NeuralCompose CLAUDE.md (project conventions and architecture)
- Evaluation data: Evaluation/2026-07-14-generation-eval/data.json
- Statistical analysis: Evaluation/reports/statistical_analysis.md
- Model survey: Evaluation/reports/model_survey.md
- Benchmark scripts: Evaluation/scripts/