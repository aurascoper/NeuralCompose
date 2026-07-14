# NeuralCompose Evaluation Dashboard

**Generated:** 2026-07-14T09:27:23.424667+00:00 — by `Evaluation/scripts/generate_dashboard.py` (do not hand-edit)

## Validation status

**FAIL** — 16 failure(s), 30 warning(s) (`validate_checkpoints.py` for details)

## Embedding track — 7 of 17 candidates evaluated

| Candidate | Priority | Runtime status |
|-----------|----------|----------------|
| bge-small-en-v1.5 | 1 | python: evaluated |
| bge-small-en-v1.5-mlx | 1 | mlx: failed: Model type bert not supported.; python: failed: weight_size_mismatch |
| bge-m3 | 10 | python: evaluated |
| stella_en_400M_v5 | 10 | python: failed: Error no file named model.safetensors, or pytorch_model.bin, found in directory /Users/aurascoper/Developer/NeuralCompose/Models/stella_en_400M_v5-hf. |
| jina-embeddings-v3 | 11 | python: failed: repo_or_file_missing |
| snowflake-arctic-embed | 11 | python: failed: Error no file named model.safetensors, or pytorch_model.bin, found in directory /Users/aurascoper/Developer/NeuralCompose/Models/snowflake-arctic-embed-hf. |
| multilingual-e5-large | 12 | python: failed: Error no file named model.safetensors, or pytorch_model.bin, found in directory /Users/aurascoper/Developer/NeuralCompose/Models/multilingual-e5-large-hf. |
| mxbai-embed-large-v1 | 12 | python: evaluated |
| bge-base-en-v1.5 | 2 | python: evaluated |
| multilingual-e5-small | 3 | python: evaluated |
| all-MiniLM-L6-v2 | 4 | python: evaluated |
| all-MiniLM-L6-v2-mlx | 4 | mlx: failed: Model type bert not supported.; python: failed: weight_size_mismatch |
| gte-base-en-v1.5 | 5 | python: failed: repo_or_file_missing |
| multilingual-e5-base | 6 | python: in progress |
| gte-large-en-v1.5 | 7 | python: failed: unclassified |
| nomic-embed-text-v1.5 | 8 | python: failed: repo_or_file_missing |
| Qwen3-Embedding-0.6B | 9 | python: evaluated |

## Generation track — 10 of 18 candidates evaluated (fixture: `generation_eval_candidates_v3.json`)

| Candidate | Directory | Status |
|-----------|-----------|--------|
| qwen2.5-0.5b | Qwen2.5-0.5B-Instruct-4bit | evaluated |
| qwen2.5-1.5b | Qwen2.5-1.5B-Instruct-4bit | evaluated |
| qwen2.5-3b | Qwen2.5-3B-Instruct-4bit | evaluated |
| qwen3-1.7b | Qwen3-1.7B-4bit | failed: wrong repo name in fixture (correct: mlx-community/Qwen3-1.7B-4bit) |
| qwen3-4b | Qwen3-4B-4bit | failed: wrong repo name in fixture (correct: mlx-community/Qwen3-4B-4bit may not exist) |
| gemma-3n-e2b | gemma-3n-E2B-it-lm-4bit | evaluated |
| gemma-3n-e4b | gemma-3n-E4B-it-lm-4bit | evaluated |
| gemma-3-1b | gemma-3-1b-it-4bit | evaluated |
| gemma-3-4b | gemma-3-4b-it-4bit | failed: download_timeout (2.3GB, network too slow) |
| phi-3.5-mini | Phi-3.5-mini-instruct-4bit | evaluated |
| phi-4-mini | Phi-4-mini-instruct-4bit | evaluated |
| smollm2-360m | SmolLM2-360M-Instruct-6bit | failed: wrong repo name in fixture (correct: mlx-community/SmolLM2-360M-Instruct-6bit) |
| smollm2-1.7b | SmolLM2-1.7B-Instruct | failed: download_timeout (full-precision 3.4GB, no 4-bit MLX version exists) |
| llama-3.2-1b | Llama-3.2-1B-Instruct-4bit | evaluated |
| llama-3.2-3b | Llama-3.2-3B-Instruct-4bit | evaluated |
| tinyllama-1.1b | TinyLlama-1.1B-Chat-v1.0-4bit | failed: download_interrupted |
| openelm-1.1b | OpenELM-1_1B-Instruct-4bit | failed: not attempted (download interrupted) |
| openelm-3b | OpenELM-3B-Instruct-4bit | unavailable: mlx-community has no OpenELM-3B instruct conversion (only ba… |

## Artifacts

### Leaderboards

- [results/embeddings/leaderboard.md](results/embeddings/leaderboard.md)
- [results/leaderboard.md](results/leaderboard.md)

### Summaries & statistics

- [results/embeddings/summary.md](results/embeddings/summary.md)
- [results/embeddings/statistical_analysis.md](results/embeddings/statistical_analysis.md)
- [results/summary.md](results/summary.md)
- [results/statistical_analysis.json](results/statistical_analysis.json)
- [results/embeddings/compatibility_matrix.md](results/embeddings/compatibility_matrix.md)

### Stage 3.4 analyses

- [results/stage_3_4/cross_runtime_consistency.md](results/stage_3_4/cross_runtime_consistency.md)
- [results/stage_3_4/cross_model_agreement.md](results/stage_3_4/cross_model_agreement.md)
- [results/stage_3_4/embedding_space_analysis.md](results/stage_3_4/embedding_space_analysis.md)
- [results/stage_3_4/generator_comparison.md](results/stage_3_4/generator_comparison.md)

### Registries & reports

- [corpora/hypothesis_registry.json](corpora/hypothesis_registry.json)
- [reports/decision_registry.md](reports/decision_registry.md)
- [reports/final_recommendation.md](reports/final_recommendation.md)
- [reports/model_survey.md](reports/model_survey.md)
- [reports/statistical_analysis.md](reports/statistical_analysis.md)
- [reports/stage_3_4_audit.md](reports/stage_3_4_audit.md)
- [reports/throughput_discrepancy.md](reports/throughput_discrepancy.md)

### Reproducibility

- [results/repro/repro_report.md](results/repro/repro_report.md) *(not yet generated)*

### Plots

- [plots/](plots/)
- [results/embeddings/plots/](results/embeddings/plots/)
