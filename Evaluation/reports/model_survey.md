# Model Survey for NeuralCompose: MLX-Compatible Instruction-Tuned LLMs for Apple Silicon

## Executive Summary

This survey catalogs all instruction-tuned language models ≤4B parameters suitable for on-device MLX inference on Apple Silicon, with a focus on NeuralCompose's use case: EEG-driven communication assistance requiring fast next-word prediction, concise text rewriting, filler removal, punctuation restoration, capitalization, command reformulation, and technical-term preservation — all offline on a 16GB RAM M4 Mac.

**18 candidates** across 9 model families were identified and ranked. The top 5 candidates by expected suitability are:

1. **Qwen2.5-0.5B-Instruct** — fastest (40.9 tok/s measured), lowest memory (708 MB), acceptable quality
2. **Qwen2.5-1.5B-Instruct** — likely 2-3x slower but significantly better instruction following
3. **Gemma-3-1B-it** — potentially the latency/quality sweet spot; untested
4. **Llama-3.2-1B-Instruct** — Meta's edge model; strong instruction tuning
5. **SmolLM2-1.7B-Instruct** — HuggingFace's edge-optimized model; good chat template

The currently evaluated Gemma-3n-E2B ranks lower on latency (7.2 tok/s measured) but higher on quality (0.771 cosine). It remains a viable optional backend for latency-tolerant tasks.

**Status update (2026-07-14):** the gap below is closed — **16 of 18 candidates are now benchmarked** (gemma-3-4b: recorded smoke-test failure, unsupported by the pinned mlx-swift; openelm-3b: recorded unavailable, no instruct conversion). Measured results live in the frozen leaderboard (`Evaluation/results/leaderboard.md`). Notable survey-hypothesis outcomes: the #1 survey pick qwen2.5-0.5b measured #2 on composite score; tinyllama-1.1b — not in the survey's top 5 — measured #1 (0.843), though the gap is within observed run-to-run variance on quality components (`repro_report.md`); survey pick #3 gemma-3-1b measured mid-pack (#7) with instruction-following 0.0 on the scored subset.

**Critical gap (as written 2026-07-13, now historical):** Only 2 of 18 candidates have been benchmarked. The survey identifies expected characteristics based on architecture, parameter count, and published benchmarks, but these are hypotheses requiring validation — explicitly marked as such.

## Methodology

### Selection Criteria

- **MLX compatible:** A model must have an mlx-community conversion on HuggingFace, or be convertible via `mlx_lm.convert`. The mlx-swift-examples library (vendored in NeuralCompose) provides Swift model implementations for Qwen2, Qwen3, Gemma, Gemma2, Gemma3n, Gemma3, Phi, Phi3, PhiMoE, Llama, SmolLM3, OpenELM, Starcoder2, and others — these are the architecture families that load without custom Swift code.
- **Instruction/chat tuned:** Base models without instruction tuning are excluded — NeuralCompose needs a model that follows rewrite instructions, not just continues text.
- **≤4B parameters:** Hard limit. The 16GB RAM M4 must run the LLM alongside EEG processing, Core ML classifier, and SwiftUI UI. Budget: ~2-3 GB for the LLM.
- **Preferably ≤2B:** Smaller is better for interactive latency.
- **Permissive license:** Commercial use permitted. GPL/AGPL or restrictive research-only licenses noted but not excluded from survey.
- **Usable offline:** No network dependency at inference time. All candidates meet this by virtue of being local MLX models.

### Data Sources

- HuggingFace model cards (huggingface.co)
- mlx-community organization (huggingface.co/mlx-community)
- mlx-swift-examples model registry (github.com/ml-explore/mlx-swift-examples)
- Published technical reports (linked per model)
- NeuralCompose's own benchmark data (Evaluation/2026-07-14-generation-eval/data.json)

### Rating Scale

- **Instruction-following (1-5):** 5=reliably follows rewrite/format instructions without preamble; 1=ignores instructions entirely
- **Rewrite quality (1-5):** 5=clean, meaning-preserving rewrites; 1=hallucinates or destroys meaning
- **Hallucination tendency (low/medium/high):** based on published reports and observed behavior
- **Verbosity (low/medium/high):** based on typical output length relative to input
- **Expected throughput:** estimated from architecture, parameter count, and measured data points. Actual throughput depends on quantization, KV cache implementation, and Metal kernel optimization.

### Caveats

All ratings marked "expected" are hypotheses based on architecture and published data, not direct measurement. Only Qwen2.5-0.5B and Gemma-3n-E2B have measured NeuralCompose benchmark data. The remaining 16 candidates need to be downloaded and benchmarked with the GenerationEval harness before their ratings can be considered validated.

## Per-Model Detailed Tables

### 1. Qwen2.5 (0.5B, 1.5B, 3B Instruct)

The Qwen2.5 series by Alibaba Cloud is a family of decoder-only transformers with ChatML-formatted instruction tuning. Qwen2.5-Instruct models are trained on a 18T-token corpus with specific instruction-following and code-generation training.

| Property | Qwen2.5-0.5B-Instruct | Qwen2.5-1.5B-Instruct | Qwen2.5-3B-Instruct |
|----------|----------------------|----------------------|---------------------|
| HF repo | [Qwen/Qwen2.5-0.5B-Instruct](https://huggingface.co/Qwen/Qwen2.5-0.5B-Instruct) | [Qwen/Qwen2.5-1.5B-Instruct](https://huggingface.co/Qwen/Qwen2.5-1.5B-Instruct) | [Qwen/Qwen2.5-3B-Instruct](https://huggingface.co/Qwen/Qwen2.5-3B-Instruct) |
| MLX repo | [mlx-community/Qwen2.5-0.5B-Instruct-4bit](https://huggingface.co/mlx-community/Qwen2.5-0.5B-Instruct-4bit) | [mlx-community/Qwen2.5-1.5B-Instruct-4bit](https://huggingface.co/mlx-community/Qwen2.5-1.5B-Instruct-4bit) | [mlx-community/Qwen2.5-3B-Instruct-4bit](https://huggingface.co/mlx-community/Qwen2.5-3B-Instruct-4bit) |
| MLX available | Yes (verified) | Yes (verified) | Yes (verified) |
| Recommended quant | 4-bit | 4-bit | 4-bit |
| Parameters | 0.5B | 1.5B | 3B |
| RAM (4-bit, est.) | ~0.5 GB | ~1.2 GB | ~2.2 GB |
| Disk (4-bit, est.) | ~0.4 GB | ~1.0 GB | ~1.8 GB |
| Throughput (tok/s, est.) | 35-50 (measured: 40.9) | 15-25 (expected) | 8-15 (expected) |
| Cold load (s, est.) | 2-3 (measured: 2.64) | 5-8 (expected) | 10-15 (expected) |
| Instruction following | 2/5 (measured) | 3/5 (expected) | 4/5 (expected) |
| Rewrite quality | 2/5 (measured) | 3/5 (expected) | 4/5 (expected) |
| Hallucination | medium (measured: ignores filler-removal task) | low-medium (expected) | low (expected) |
| Verbosity | high (measured: 3.32x word count ratio) | medium (expected) | medium (expected) |
| License | Qwen License (commercial use permitted with restrictions) | Same | Same |
| Maintenance | Active (Alibaba Cloud, regular updates) | Active | Active |
| Known limitations | 0.5B: poor instruction following on non-trivial tasks, conversational preamble, hallucination on filler-removal. 3B: may be too slow for interactive EEG use. | | |
| Citations | [Qwen2.5 Technical Report](https://qwenlm.github.io/blog/qwen2.5/), [Qwen2.5 paper](https://arxiv.org/abs/2412.15115) | | |

**Measured data (0.5B):** 40.9 tok/s, 1.15s mean generation, 708 MB peak RSS, 0.744 meaning-preservation cosine. Both models eliminate the previously observed decoder-loop pathology. Source: Evaluation/2026-07-14-generation-eval/data.json

### 2. Qwen3 (1.7B, 4B Instruct)

Qwen3 is the successor to Qwen2.5, released in 2025. It introduces a "thinking mode" toggle for reasoning vs. fast response. The small instruct variants are relevant for edge deployment.

| Property | Qwen3-1.7B-Instruct | Qwen3-4B-Instruct |
|----------|---------------------|-------------------|
| HF repo | [Qwen/Qwen3-1.7B-Instruct](https://huggingface.co/Qwen/Qwen3-1.7B-Instruct) | [Qwen/Qwen3-4B-Instruct](https://huggingface.co/Qwen/Qwen3-4B-Instruct) |
| MLX repo | [mlx-community/Qwen3-1.7B-Instruct-4bit](https://huggingface.co/mlx-community/Qwen3-1.7B-Instruct-4bit) | [mlx-community/Qwen3-4B-Instruct-4bit](https://huggingface.co/mlx-community/Qwen3-4B-Instruct-4bit) |
| MLX available | Yes (expected; Qwen3 architecture is in mlx-swift-examples) | Yes (expected) |
| Recommended quant | 4-bit | 4-bit |
| Parameters | 1.7B | 4B |
| RAM (4-bit, est.) | ~1.4 GB | ~2.8 GB |
| Disk (4-bit, est.) | ~1.1 GB | ~2.3 GB |
| Throughput (tok/s, est.) | 12-20 (expected) | 5-10 (expected) |
| Cold load (s, est.) | 5-8 (expected) | 12-18 (expected) |
| Instruction following | 4/5 (expected — improved over Qwen2.5) | 4/5 (expected) |
| Rewrite quality | 4/5 (expected) | 4/5 (expected) |
| Hallucination | low (expected) | low (expected) |
| Verbosity | medium (expected — thinking mode may add reasoning preamble) | medium (expected) |
| License | Qwen License | Qwen License |
| Maintenance | Active | Active |
| Known limitations | Thinking mode may produce verbose intermediate reasoning. 4B is at the parameter limit. | |
| Citations | [Qwen3 blog post](https://qwenlm.github.io/blog/qwen3/) | |

### 3. Gemma 3n (E2B, E4B)

Gemma 3n is Google's "edge-optimized" variant of Gemma 3, using a "MatFormer" architecture with pruned KV cache layers for reduced memory. The "E2B" designation means "effective 2B" parameters — the total parameter count is higher but only ~2B are active during inference due to the MatFormer routing.

| Property | Gemma-3n-E2B-it-lm | Gemma-3n-E4B-it-lm |
|----------|-------------------|-------------------|
| HF repo | [google/gemma-3n-E2B-it-lm](https://huggingface.co/google/gemma-3n-E2B-it-lm) | [google/gemma-3n-E4B-it-lm](https://huggingface.co/google/gemma-3n-E4B-it-lm) |
| MLX repo | [mlx-community/gemma-3n-E2B-it-lm-4bit](https://huggingface.co/mlx-community/gemma-3n-E2B-it-lm-4bit) | [mlx-community/gemma-3n-E4B-it-lm-4bit](https://huggingface.co/mlx-community/gemma-3n-E4B-it-lm-4bit) |
| MLX available | Yes (verified — currently in NeuralCompose) | Yes (expected) |
| Recommended quant | 4-bit | 4-bit |
| Parameters | ~2B effective (~5B total, pruned) | ~4B effective (~8B total, pruned) |
| RAM (4-bit, est.) | ~0.9 GB (measured: 858 MB peak RSS) | ~1.8 GB (expected) |
| Disk (4-bit, est.) | ~1.5 GB | ~3.0 GB |
| Throughput (tok/s, est.) | 7-8 (measured: 7.2) | 3-5 (expected) |
| Cold load (s, est.) | 10-12 (measured: 11.77) | 20-30 (expected) |
| Instruction following | 3/5 (measured — better than Qwen-0.5B on simple tasks, but verbose) | 4/5 (expected) |
| Rewrite quality | 3/5 (measured — higher cosine but extensive preamble) | 4/5 (expected) |
| Hallucination | low (measured) | low (expected) |
| Verbosity | high (measured: 4.62x word count ratio, extensive conversational preamble) | high (expected) |
| License | Gemma Terms of Use (commercial use permitted) | Same |
| Maintenance | Active (Google) | Active |
| Known limitations | Very slow (7.2 tok/s) for interactive use. Pruned KV layers require strict=False loading. Extensive conversational preamble ("Okay!", "Let me know if..."). Emoji in outputs. | E4B likely too slow and too large for the 16GB budget. |
| Citations | [Gemma 3n model card](https://huggingface.co/google/gemma-3n-E2B-it-lm), [Gemma 3 technical report](https://arxiv.org/abs/2403.19730) | |

**Measured data (E2B):** 7.2 tok/s, 12.77s mean generation, 858 MB peak RSS, 0.771 meaning-preservation cosine. Correctly responds "Yes." to "Say the word yes" (Qwen-0.5B produces a paragraph). Correctly continues sequence "E" after A/B/C/D (Qwen produces garbled output). Source: Evaluation/2026-07-14-generation-eval/data.json

### 4. Gemma 3 (1B, 2B, 4B Instruct)

Gemma 3 is Google's standard (non-edge) instruction-tuned model family. Unlike 3n, it uses the standard transformer architecture without MatFormer pruning. The 1B and 2B variants are of particular interest as potential latency/quality sweet spots.

| Property | Gemma-3-1b-it | Gemma-3-4b-it |
|----------|--------------|--------------|
| HF repo | [google/gemma-3-1b-it](https://huggingface.co/google/gemma-3-1b-it) | [google/gemma-3-4b-it](https://huggingface.co/google/gemma-3-4b-it) |
| MLX repo | [mlx-community/gemma-3-1b-it-4bit](https://huggingface.co/mlx-community/gemma-3-1b-it-4bit) | [mlx-community/gemma-3-4b-it-4bit](https://huggingface.co/mlx-community/gemma-3-4b-it-4bit) |
| MLX available | Yes (Gemma3Text architecture in mlx-swift-examples) | Yes |
| Recommended quant | 4-bit | 4-bit |
| Parameters | 1B | 4B |
| RAM (4-bit, est.) | ~0.8 GB | ~2.5 GB |
| Disk (4-bit, est.) | ~0.7 GB | ~2.3 GB |
| Throughput (tok/s, est.) | 20-35 (expected — standard architecture, fewer params than E2B) | 5-10 (expected) |
| Cold load (s, est.) | 3-6 (expected) | 12-18 (expected) |
| Instruction following | 3/5 (expected — Gemma family instruction tuning) | 4/5 (expected) |
| Rewrite quality | 3/5 (expected) | 4/5 (expected) |
| Hallucination | low (expected) | low (expected) |
| Verbosity | high (expected — Gemma family tends toward conversational preamble) | medium (expected) |
| License | Gemma Terms of Use | Same |
| Maintenance | Active (Google) | Active |
| Known limitations | Standard architecture (no MatFormer pruning) means full KV cache — may use more memory than E2B at same effective quality. Gemma family verbosity. | 4B is at parameter limit. |
| Citations | [Gemma 3 technical report](https://arxiv.org/abs/2403.19730), [Gemma 3 model card](https://huggingface.co/google/gemma-3-1b-it) | |

**Key hypothesis:** Gemma-3-1b-it may be the latency/quality sweet spot — standard 1B architecture should be faster than E2B's pruned 2B, while retaining Gemma family instruction tuning. **This is the highest-priority untested candidate.**

### 5. Phi-3.5 Mini (3.8B)

Microsoft's Phi-3.5 Mini is a 3.8B-parameter decoder-only model trained on "textbook quality" synthetic data. Known for punching above its weight on reasoning tasks.

| Property | Phi-3.5-mini-instruct |
|----------|----------------------|
| HF repo | [microsoft/Phi-3.5-mini-instruct](https://huggingface.co/microsoft/Phi-3.5-mini-instruct) |
| MLX repo | [mlx-community/Phi-3.5-mini-instruct-4bit](https://huggingface.co/mlx-community/Phi-3.5-mini-instruct-4bit) |
| MLX available | Yes (Phi3 architecture in mlx-swift-examples) |
| Recommended quant | 4-bit |
| Parameters | 3.8B |
| RAM (4-bit, est.) | ~2.5 GB |
| Disk (4-bit, est.) | ~2.2 GB |
| Throughput (tok/s, est.) | 5-10 (expected — 3.8B at 4-bit on M4) |
| Cold load (s, est.) | 10-15 (expected) |
| Instruction following | 4/5 (expected — Phi models are specifically trained for instruction following) |
| Rewrite quality | 4/5 (expected) |
| Hallucination | low (expected — Phi training data is curated for quality) |
| Verbosity | medium (expected — Phi models tend to be more concise than Gemma) |
| License | MIT (highly permissive) |
| Maintenance | Active (Microsoft) |
| Known limitations | 3.8B may be too slow for interactive EEG use. Chat template uses `<|end|>` EOS token. |
| Citations | [Phi-3.5 technical report](https://arxiv.org/abs/2404.14219), [Phi-3.5 model card](https://huggingface.co/microsoft/Phi-3.5-mini-instruct) |

### 6. Phi-4 Mini (3.8B)

Phi-4 Mini is the successor to Phi-3.5 Mini, released in late 2024. It introduces improved reasoning and code generation capabilities.

| Property | Phi-4-mini-instruct |
|----------|--------------------|
| HF repo | [microsoft/Phi-4-mini-instruct](https://huggingface.co/microsoft/Phi-4-mini-instruct) |
| MLX repo | [mlx-community/Phi-4-mini-instruct-4bit](https://huggingface.co/mlx-community/Phi-4-mini-instruct-4bit) |
| MLX available | Yes (expected — Phi3 architecture supports Phi-4) |
| Recommended quant | 4-bit |
| Parameters | 3.8B |
| RAM (4-bit, est.) | ~2.5 GB |
| Disk (4-bit, est.) | ~2.2 GB |
| Throughput (tok/s, est.) | 5-10 (expected) |
| Cold load (s, est.) | 10-15 (expected) |
| Instruction following | 4/5 (expected — improved over Phi-3.5) |
| Rewrite quality | 4/5 (expected) |
| Hallucination | low (expected) |
| Verbosity | low-medium (expected — Phi-4 is reported to be more concise) |
| License | MIT (highly permissive) |
| Maintenance | Active (Microsoft) |
| Known limitations | Same latency concerns as Phi-3.5 at 3.8B. Newer model — less community validation. |
| Citations | [Phi-4 technical report](https://arxiv.org/abs/2412.08905), [Phi-4 model card](https://huggingface.co/microsoft/Phi-4-mini-instruct) |

### 7. SmolLM2 (135M, 360M, 1.7B Instruct)

SmolLM2 is HuggingFace's (HuggingFaceTB) edge-oriented model family, specifically designed for on-device inference. Trained on 11T tokens of curated data including Cosmopedia v2 (synthetic educational content).

| Property | SmolLM2-135M-Instruct | SmolLM2-360M-Instruct | SmolLM2-1.7B-Instruct |
|----------|----------------------|----------------------|----------------------|
| HF repo | [HuggingFaceTB/SmolLM2-135M-Instruct](https://huggingface.co/HuggingFaceTB/SmolLM2-135M-Instruct) | [HuggingFaceTB/SmolLM2-360M-Instruct](https://huggingface.co/HuggingFaceTB/SmolLM2-360M-Instruct) | [HuggingFaceTB/SmolLM2-1.7B-Instruct](https://huggingface.co/HuggingFaceTB/SmolLM2-1.7B-Instruct) |
| MLX repo | [mlx-community/SmolLM2-135M-Instruct-4bit](https://huggingface.co/mlx-community/SmolLM2-135M-Instruct-4bit) | [mlx-community/SmolLM2-360M-Instruct-4bit](https://huggingface.co/mlx-community/SmolLM2-360M-Instruct-4bit) | [mlx-community/SmolLM2-1.7B-Instruct-4bit](https://huggingface.co/mlx-community/SmolLM2-1.7B-Instruct-4bit) |
| MLX available | Yes (SmolLM3 architecture in mlx-swift-examples supports SmolLM2) | Yes | Yes |
| Recommended quant | 4-bit (or unquantized — 135M fits in any budget) | 4-bit | 4-bit |
| Parameters | 135M | 360M | 1.7B |
| RAM (4-bit, est.) | ~0.1 GB | ~0.25 GB | ~1.3 GB |
| Disk (4-bit, est.) | ~0.1 GB | ~0.2 GB | ~1.0 GB |
| Throughput (tok/s, est.) | 80-120 (expected — very small model) | 60-90 (expected) | 15-25 (expected) |
| Cold load (s, est.) | <1 (expected) | 1-2 (expected) | 4-7 (expected) |
| Instruction following | 1/5 (expected — too small for complex instructions) | 2/5 (expected) | 3/5 (expected) |
| Rewrite quality | 1/5 (expected) | 2/5 (expected) | 3/5 (expected) |
| Hallucination | high (expected — small models hallucinate more) | medium (expected) | low-medium (expected) |
| Verbosity | low (expected — small models produce short outputs) | low (expected) | medium (expected) |
| License | Apache 2.0 (highly permissive) | Apache 2.0 | Apache 2.0 |
| Maintenance | Active (HuggingFace) | Active | Active |
| Known limitations | 135M and 360M are likely too small for meaningful rewrite quality. 1.7B is the interesting candidate — HuggingFace's own benchmarks show it outperforming Qwen2.5-0.5B on instruction following. | | |
| Citations | [SmolLM2 blog post](https://huggingface.co/blog/smollm2), [SmolLM2 model card](https://huggingface.co/HuggingFaceTB/SmolLM2-1.7B-Instruct) | | |

### 8. TinyLlama (1.1B Chat)

TinyLlama is a compact 1.1B model trained on 3T tokens, based on the Llama 2 architecture. It's one of the older edge models but has wide community support.

| Property | TinyLlama-1.1B-Chat-v1.0 |
|----------|--------------------------|
| HF repo | [TinyLlama/TinyLlama-1.1B-Chat-v1.0](https://huggingface.co/TinyLlama/TinyLlama-1.1B-Chat-v1.0) |
| MLX repo | [mlx-community/TinyLlama-1.1B-Chat-v1.0-4bit](https://huggingface.co/mlx-community/TinyLlama-1.1B-Chat-v1.0-4bit) |
| MLX available | Yes (Llama architecture in mlx-swift-examples) |
| Recommended quant | 4-bit |
| Parameters | 1.1B |
| RAM (4-bit, est.) | ~0.8 GB |
| Disk (4-bit, est.) | ~0.7 GB |
| Throughput (tok/s, est.) | 25-40 (expected — Llama architecture, small model) |
| Cold load (s, est.) | 2-4 (expected) |
| Instruction following | 2/5 (expected — older model, weaker instruction tuning) |
| Rewrite quality | 2/5 (expected) |
| Hallucination | medium (expected) |
| Verbosity | medium (expected) |
| License | Apache 2.0 (highly permissive) |
| Maintenance | Stale (last update ~2024, superseded by newer edge models) |
| Known limitations | Older model with weaker instruction tuning compared to Qwen2.5 or SmolLM2. Llama 2 architecture (no GQA, less efficient KV cache). Likely lower quality than same-size newer models. |
| Citations | [TinyLlama GitHub](https://github.com/jzhang38/TinyLlama), [TinyLlama model card](https://huggingface.co/TinyLlama/TinyLlama-1.1B-Chat-v1.0) |

### 9. OpenELM (270M, 450M, 1.1B, 3B Instruct)

OpenELM is Apple's own open-source language model family, specifically designed for on-device inference. Of special interest for Apple Silicon optimization, though MLX performance is not guaranteed to be superior just because the model and framework share a vendor.

| Property | OpenELM-270M-Instruct | OpenELM-450M-Instruct | OpenELM-1_1B-Instruct | OpenELM-3B-Instruct |
|----------|----------------------|----------------------|----------------------|---------------------|
| HF repo | [apple/OpenELM-270M-Instruct](https://huggingface.co/apple/OpenELM-270M-Instruct) | [apple/OpenELM-450M-Instruct](https://huggingface.co/apple/OpenELM-450M-Instruct) | [apple/OpenELM-1_1B-Instruct](https://huggingface.co/apple/OpenELM-1_1B-Instruct) | [apple/OpenELM-3B-Instruct](https://huggingface.co/apple/OpenELM-3B-Instruct) |
| MLX repo | [mlx-community/OpenELM-270M-Instruct-4bit](https://huggingface.co/mlx-community/OpenELM-270M-Instruct-4bit) | [mlx-community/OpenELM-450M-Instruct-4bit](https://huggingface.co/mlx-community/OpenELM-450M-Instruct-4bit) | [mlx-community/OpenELM-1_1B-Instruct-4bit](https://huggingface.co/mlx-community/OpenELM-1_1B-Instruct-4bit) | [mlx-community/OpenELM-3B-Instruct-4bit](https://huggingface.co/mlx-community/OpenELM-3B-Instruct-4bit) |
| MLX available | Yes (OpenELM architecture in mlx-swift-examples) | Yes | Yes | Yes |
| Recommended quant | 4-bit (or unquantized) | 4-bit | 4-bit | 4-bit |
| Parameters | 270M | 450M | 1.1B | 3B |
| RAM (4-bit, est.) | ~0.2 GB | ~0.3 GB | ~0.8 GB | ~2.0 GB |
| Disk (4-bit, est.) | ~0.15 GB | ~0.25 GB | ~0.7 GB | ~1.7 GB |
| Throughput (tok/s, est.) | 60-100 (expected) | 40-70 (expected) | 20-35 (expected) | 8-15 (expected) |
| Cold load (s, est.) | 1-2 (expected) | 1-3 (expected) | 3-5 (expected) | 10-15 (expected) |
| Instruction following | 1/5 (expected — too small) | 2/5 (expected) | 2/5 (expected — weak instruction tuning vs. Qwen/Gemma) | 3/5 (expected) |
| Rewrite quality | 1/5 (expected) | 2/5 (expected) | 2/5 (expected) | 3/5 (expected) |
| Hallucination | high (expected) | medium-high (expected) | medium (expected) | low-medium (expected) |
| Verbosity | low (expected) | low (expected) | medium (expected) | medium (expected) |
| License | Apple Sample Code License (non-commercial research use only — **restrictive**) | Same | Same | Same |
| Maintenance | Stale (released 2024, no major updates since) | Stale | Stale | Stale |
| Known limitations | **Non-commercial license** — cannot be used in production. Weak instruction tuning compared to Qwen2.5/Gemma/Phi. Older training data. OpenELM uses a layer-wise scaling strategy that may not map perfectly to standard MLX optimizations. | | | |
| Citations | [OpenELM paper](https://arxiv.org/abs/2404.14619), [OpenELM model card](https://huggingface.co/apple/OpenELM-3B-Instruct) | | | |

**Important:** OpenELM's Apple Sample Code License is non-commercial. This **disqualifies it for production use** in NeuralCompose if the project has any commercial intent. It is included in the survey for completeness and as a benchmark reference.

### 10. Llama 3.2 (1B, 3B Instruct)

Llama 3.2 is Meta's edge-optimized model family, released alongside the larger Llama 3.1 models. The 1B and 3B "lightweight" models are specifically designed for on-device inference.

| Property | Llama-3.2-1B-Instruct | Llama-3.2-3B-Instruct |
|----------|----------------------|----------------------|
| HF repo | [meta-llama/Llama-3.2-1B-Instruct](https://huggingface.co/meta-llama/Llama-3.2-1B-Instruct) | [meta-llama/Llama-3.2-3B-Instruct](https://huggingface.co/meta-llama/Llama-3.2-3B-Instruct) |
| MLX repo | [mlx-community/Llama-3.2-1B-Instruct-4bit](https://huggingface.co/mlx-community/Llama-3.2-1B-Instruct-4bit) | [mlx-community/Llama-3.2-3B-Instruct-4bit](https://huggingface.co/mlx-community/Llama-3.2-3B-Instruct-4bit) |
| MLX available | Yes (Llama architecture in mlx-swift-examples) | Yes |
| Recommended quant | 4-bit | 4-bit |
| Parameters | 1B | 3B |
| RAM (4-bit, est.) | ~0.8 GB | ~2.2 GB |
| Disk (4-bit, est.) | ~0.7 GB | ~1.8 GB |
| Throughput (tok/s, est.) | 25-40 (expected — optimized for edge) | 10-18 (expected) |
| Cold load (s, est.) | 2-4 (expected) | 8-12 (expected) |
| Instruction following | 3/5 (expected — Meta's instruction tuning is strong) | 4/5 (expected) |
| Rewrite quality | 3/5 (expected) | 4/5 (expected) |
| Hallucination | low (expected — Llama 3 family has strong alignment) | low (expected) |
| Verbosity | medium (expected — Llama 3 tends toward detailed responses) | medium (expected) |
| License | Llama 3.2 Community License (commercial use permitted with restrictions: <700M MAU) | Same |
| Maintenance | Active (Meta) | Active |
| Known limitations | Llama 3.2 license has a MAU cap (>700M monthly active users requires Meta permission). 1B is a key untested candidate — Meta's edge optimization may give it a latency advantage. | 3B may be too slow for interactive EEG use. |
| Citations | [Llama 3.2 model card](https://huggingface.co/meta-llama/Llama-3.2-1B-Instruct), [Llama 3 technical report](https://arxiv.org/abs/2407.21783) | |

### 11. DeepSeek Small Variants

DeepSeek does not currently offer instruction-tuned models ≤4B parameters. The smallest DeepSeek instruct model is DeepSeek-V2-Lite-Chat (16B MoE). No MLX-converted DeepSeek model ≤4B exists on HuggingFace as of this survey.

**Status:** No qualifying candidates. DeepSeek is excluded from the ranking.

### 12. Mistral Small Variants

Mistral's smallest instruction-tuned model is Mistral-7B-Instruct, which exceeds the 4B parameter limit. Mistral released "Ministral 3B" (a.k.a. Mistral-3B-Instruct) in late 2024, but it requires a Mistral API key for download and has a custom commercial license that may not qualify as "permissive" for all use cases.

| Property | Ministral-3B |
|----------|-------------|
| HF repo | [mistralai/Ministral-3B-Instruct-2412](https://huggingface.co/mistralai/Ministral-3B-Instruct-2412) |
| MLX repo | May exist via mlx-community, but gated access makes verification difficult |
| MLX available | Unknown (gated model) |
| Parameters | 3B |
| License | Mistral Research License (non-commercial) or Commercial License |
| Known limitations | **Gated access** — requires Mistral API key. Research license is non-commercial. Excluded from ranking due to licensing and access constraints. |

**Status:** Excluded from ranking due to licensing and access constraints.

## Ranking Table

Ranking considers: latency (critical for EEG communication), instruction-following quality, rewrite quality, conciseness, memory budget, license permissiveness, and MLX availability.

| Rank | Model | Params | Est. tok/s | Est. RAM | Instr. Follow | Rewrite | License | Rationale |
|------|-------|--------|-----------|----------|--------------|---------|---------|-----------|
| 1 | Qwen2.5-0.5B-Instruct-4bit | 0.5B | 41 (measured) | 0.5 GB | 2/5 | 2/5 | Qwen (commercial) | Fastest, lowest memory, already integrated. Quality is weak but latency is binding. |
| 2 | Qwen2.5-1.5B-Instruct-4bit | 1.5B | 15-25 (exp.) | 1.2 GB | 3/5 | 3/5 | Qwen (commercial) | Likely 2-3x slower but significantly better instruction following. **Highest priority to benchmark.** |
| 3 | Gemma-3-1b-it-4bit | 1B | 20-35 (exp.) | 0.8 GB | 3/5 | 3/5 | Gemma (commercial) | Potential sweet spot. Standard architecture should be faster than E2B. **Second priority.** |
| 4 | Llama-3.2-1B-Instruct-4bit | 1B | 25-40 (exp.) | 0.8 GB | 3/5 | 3/5 | Llama 3.2 (commercial, MAU cap) | Meta's edge optimization. Strong instruction tuning. MAU cap is a concern for large deployments. |
| 5 | SmolLM2-1.7B-Instruct-4bit | 1.7B | 15-25 (exp.) | 1.3 GB | 3/5 | 3/5 | Apache 2.0 | HF's edge model. Apache 2.0 is the most permissive license. Good chat template. |
| 6 | Qwen3-1.7B-Instruct-4bit | 1.7B | 12-20 (exp.) | 1.4 GB | 4/5 | 4/5 | Qwen (commercial) | Improved instruction following over Qwen2.5. Thinking mode may add preamble. |
| 7 | Gemma-3n-E2B-it-lm-4bit | ~2B eff. | 7.2 (measured) | 0.9 GB | 3/5 | 3/5 | Gemma (commercial) | Already integrated. Higher quality than Qwen-0.5B but too slow for interactive use. |
| 8 | Phi-3.5-mini-instruct-4bit | 3.8B | 5-10 (exp.) | 2.5 GB | 4/5 | 4/5 | MIT | Strong instruction following. MIT license. But likely too slow for interactive use. |
| 9 | Phi-4-mini-instruct-4bit | 3.8B | 5-10 (exp.) | 2.5 GB | 4/5 | 4/5 | MIT | Improved over Phi-3.5. MIT license. Same latency concern. |
| 10 | Qwen2.5-3B-Instruct-4bit | 3B | 8-15 (exp.) | 2.2 GB | 4/5 | 4/5 | Qwen (commercial) | Good quality but likely too slow for interactive EEG. |
| 11 | Qwen3-4B-Instruct-4bit | 4B | 5-10 (exp.) | 2.8 GB | 4/5 | 4/5 | Qwen (commercial) | At the 4B limit. Too slow for interactive use. |
| 12 | Llama-3.2-3B-Instruct-4bit | 3B | 10-18 (exp.) | 2.2 GB | 4/5 | 4/5 | Llama 3.2 (commercial, MAU cap) | Good quality but likely too slow for interactive EEG. |
| 13 | Gemma-3-4b-it-4bit | 4B | 5-10 (exp.) | 2.5 GB | 4/5 | 4/5 | Gemma (commercial) | At the 4B limit. Too slow for interactive use. |
| 14 | Gemma-3n-E4B-it-lm-4bit | ~4B eff. | 3-5 (exp.) | 1.8 GB | 4/5 | 4/5 | Gemma (commercial) | Too slow and too large. Quality ceiling reference. |
| 15 | SmolLM2-360M-Instruct-4bit | 360M | 60-90 (exp.) | 0.25 GB | 2/5 | 2/5 | Apache 2.0 | Very fast but likely too small for meaningful rewrite quality. |
| 16 | TinyLlama-1.1B-Chat-v1.0-4bit | 1.1B | 25-40 (exp.) | 0.8 GB | 2/5 | 2/5 | Apache 2.0 | Older model, weaker instruction tuning. Superseded by newer edge models. |
| 17 | OpenELM-1_1B-Instruct-4bit | 1.1B | 20-35 (exp.) | 0.8 GB | 2/5 | 2/5 | Apple SCL (**non-commercial**) | Non-commercial license disqualifies for production. |
| 18 | OpenELM-3B-Instruct-4bit | 3B | 8-15 (exp.) | 2.0 GB | 3/5 | 3/5 | Apple SCL (**non-commercial**) | Non-commercial license disqualifies for production. |

### Excluded Models

| Model | Reason |
|-------|--------|
| DeepSeek-V2-Lite-Chat (16B) | Exceeds 4B parameter limit |
| Mistral-7B-Instruct (7B) | Exceeds 4B parameter limit |
| Ministral-3B (3B) | Gated access, non-commercial research license |
| OpenELM-270M | Too small for meaningful quality (included in OpenELM row above for reference) |
| SmolLM2-135M | Too small for meaningful quality |

## References

1. Qwen2.5 Technical Report — https://qwenlm.github.io/blog/qwen2.5/
2. Qwen2.5 paper — https://arxiv.org/abs/2412.15115
3. Qwen3 blog — https://qwenlm.github.io/blog/qwen3/
4. Gemma 3 Technical Report — https://arxiv.org/abs/2403.19730
5. Gemma 3n model card — https://huggingface.co/google/gemma-3n-E2B-it-lm
6. Phi-3.5 Technical Report — https://arxiv.org/abs/2404.14219
7. Phi-4 Technical Report — https://arxiv.org/abs/2412.08905
8. SmolLM2 blog — https://huggingface.co/blog/smollm2
9. TinyLlama GitHub — https://github.com/jzhang38/TinyLlama
10. OpenELM paper — https://arxiv.org/abs/2404.14619
11. Llama 3 Technical Report — https://arxiv.org/abs/2407.21783
12. MLX framework — https://github.com/ml-explore/mlx
13. mlx-swift-examples — https://github.com/ml-explore/mlx-swift-examples
14. mlx-community HuggingFace — https://huggingface.co/mlx-community
15. NeuralCompose benchmark data — Evaluation/2026-07-14-generation-eval/data.json
16. NeuralCompose statistical analysis — Evaluation/reports/statistical_analysis.md
17. NeuralCompose final recommendation — Evaluation/reports/final_recommendation.md