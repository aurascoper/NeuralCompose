# Models/

Drop model artifacts here. Contents are gitignored.

- `IntentClassifier.mlmodelc/`   compiled Core ML classifier (Xcode-built,
                                  fastest first-launch). Preferred when present.
- `IntentClassifier.mlpackage/`  raw `.mlpackage` from
                                  `Scripts/train-intent-classifier.py`. Core ML
                                  auto-compiles on first load — no Xcode needed.
- `<MLX-model-name>/`            an MLX-converted LLM (see MODEL_SETUP.md).
                                  Note: requires full Xcode for the Metal toolchain.

If a file is missing, the corresponding pipeline stage falls back to its mock
or stub implementation and the app continues to run.
