# Models/

Drop model artifacts here. Contents are gitignored.

- `IntentClassifier.mlmodelc/`   compiled Core ML intent classifier.
- `<MLX-model-name>/`            an MLX-converted LLM (see MODEL_SETUP.md).

If a file is missing, the corresponding pipeline stage falls back to its mock
or stub implementation and the app continues to run.
