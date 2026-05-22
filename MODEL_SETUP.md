# Model setup

NeuralCompose ships with no weights. Out of the box, the app uses:

- `MockIntentClassifier`  — deterministic intent generator driven by EEG energy.
- `StubNextWordPredictor` — a tiny built-in n-gram / unigram fallback.

Drop in real models when you want them.

---

## 1. Core ML intent classifier

### File layout

```
Models/
  IntentClassifier.mlmodelc/     <- Apple's compiled Core ML bundle
```

If `IntentClassifier.mlmodelc` exists, `ClassifierFactory.live()` will load it
under the following configuration:

```swift
let config = MLModelConfiguration()
config.computeUnits = .cpuAndNeuralEngine   // ANE preferred, no GPU
config.allowLowPrecisionAccumulationOnGPU = false
```

`.cpuAndNeuralEngine` is the right setting here — it deliberately keeps work
off the GPU so MLX has unobstructed GPU access. The runtime-configurable
`ClassifierComputeMode` enum can be flipped from the UI to `.all` (let Core ML
schedule freely) or `.cpuOnly` (debug fallback). It never offers
`.neuralEngineOnly` — that case does not exist in `MLComputeUnits`.

### Expected I/O shape

The default wrapper expects:

- **Input**:  `MLMultiArray<Float32>` of shape `[1, channels, samples]`
              where `channels` defaults to 4 (TP9, AF7, AF8, TP10 for Muse)
              and `samples` defaults to 256 (1.024 s @ 256 Hz, but the
              window length is configurable in `EEGWindowingConfig`).
- **Output**: `MLMultiArray<Float32>` of shape `[1, classes]`, logits or
              probabilities for the intent labels in
              `IntentClass.modelOutputOrder`.

If your model uses different names, adjust the input/output keys in
`CoreMLIntentClassifier.swift` — that's the only place they appear.

### Compiling

```bash
xcrun coremlcompiler compile path/to/IntentClassifier.mlpackage Models/
```

---

## 2. MLX next-word predictor

### Recommended models

Pick something small enough that next-word latency stays under 200 ms on a
recent Apple Silicon mac (M1 → M4). Good starting points:

- `Qwen2.5-0.5B-Instruct-4bit`
- `Qwen2.5-1.5B-Instruct-4bit`
- `SmolLM2-360M-Instruct-4bit`
- `SmolLM2-1.7B-Instruct-4bit`
- `gemma-2-2b-it-4bit`  (heavier; may add latency on M1)
- `Phi-3.5-mini-instruct-4bit`

### Conversion

The easiest path is to download an already-MLX-converted variant from the
Hugging Face `mlx-community` org and unpack it into `Models/`:

```bash
huggingface-cli download mlx-community/Qwen2.5-0.5B-Instruct-4bit \
  --local-dir Models/Qwen2.5-0.5B-Instruct-4bit
```

The expected layout under `Models/<name>/`:

```
config.json
tokenizer.json
tokenizer_config.json
*.safetensors
```

### Pointing the app at a model

Either edit `defaultMLXModelName` in `BCILLM/PredictorFactory.swift`, or set
`NEURALCOMPOSE_MLX_MODEL=<folder name>` in the environment before launch.

### What if the model fails to load?

`MLXNextWordPredictor.init` is tolerant: if the folder is missing, the config
is malformed, or `MLXLMCommon` raises during weight load, the factory logs the
specific reason once and returns a `StubNextWordPredictor` in its place. The
app continues working in degraded mode and the privacy banner reflects it.

---

## 3. Why this split?

Core ML (ANE) for classification + MLX (GPU) for generation is the sweet spot
on Apple Silicon: the two engines don't fight for the same compute. Routing
the classifier to `.cpuAndNeuralEngine` is the load-bearing choice that keeps
the GPU free for MLX, and keeps the per-window classifier under ~3 ms even on
M1. Don't move it to `.all` unless you've profiled and confirmed it does not
contend with the LLM forward pass.
