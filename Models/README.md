# Models/

Drop model artifacts here. Contents are gitignored.

- `IntentClassifier.mlmodelc/`   compiled Core ML classifier (Xcode-built,
                                  fastest first-launch). Preferred when present.
- `IntentClassifier.mlpackage/`  raw `.mlpackage` from
                                  `Scripts/train-intent-classifier.py`. Core ML
                                  auto-compiles on first load — no Xcode needed.
- `<MLX-model-name>/`            an MLX-converted LLM (see MODEL_SETUP.md).
                                  Note: requires full Xcode for the Metal toolchain.
                                  Two backends are recognized by name —
                                  `Qwen2.5-0.5B-Instruct-4bit` (default) and
                                  `gemma-3n-E2B-it-lm-4bit` — selected via the
                                  `NEURALCOMPOSE_MLX_BACKEND` env var.

If a file is missing, the corresponding pipeline stage falls back to its mock
or stub implementation and the app continues to run.
