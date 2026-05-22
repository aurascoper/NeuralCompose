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

- **Input**:  `MLMultiArray<Float32>` of shape **`[1, 4, 512]`** (i.e.
              `[1, channels, samples]`). The `512` matches a 2 s window at
              256 Hz, which is what `EEGWindowingConfig` and `AppContainer`
              configure by default, and equals `CoreMLIntentClassifier.expectedSamples`
              out of the box. If you change `EEGWindowingConfig.windowSeconds`
              or `sampleRate`, also update `expectedSamples` — the two must
              agree, and the wrapper validates channel count at runtime.
- **Output**: `MLMultiArray<Float32>` of shape `[1, classes]`, logits or
              probabilities for the intent labels in
              `IntentClass.modelOutputOrder`.

If your model uses different names, adjust the input/output keys in
`CoreMLIntentClassifier.swift` — that's the only place they appear.

### Two file layouts, both accepted

`ClassifierFactory` looks for either:

1. **`Models/IntentClassifier.mlmodelc/`** — Xcode-compiled bundle. Fastest
   first-launch (no compile step at runtime). Requires full **Xcode.app**
   (not just Command Line Tools) since `xcrun coremlcompiler` ships only
   with Xcode:
   ```bash
   xcrun coremlcompiler compile path/to/IntentClassifier.mlpackage Models/
   ```
2. **`Models/IntentClassifier.mlpackage`** — raw export from
   `Scripts/train-intent-classifier.py` (or any coremltools `.convert()`
   call). Core ML auto-compiles on first load and caches the result. No
   Xcode required, slightly slower cold-start.

If both exist, `.mlmodelc` wins.

### Training from a calibration session

The repo ships a training script that turns one or more calibration sessions
into a `.mlpackage`:

```bash
./venv/bin/python Scripts/train-intent-classifier.py
# or scope to specific sessions:
./venv/bin/python Scripts/train-intent-classifier.py \
    ~/Documents/NeuralCompose/Recordings/calibration_<ts>_muses/
```

Architecture is a 1-D CNN (~25K params, ANE-friendly). Output:
`Models/IntentClassifier.mlpackage`. See [CALIBRATION.md](CALIBRATION.md)
for how to collect the input data.

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
Hugging Face `mlx-community` org and unpack it into `Models/`. With the
modern `hf` CLI from `huggingface_hub`:

```bash
hf download mlx-community/Qwen2.5-0.5B-Instruct-4bit \
  --local-dir Models/Qwen2.5-0.5B-Instruct-4bit
```

(The older `huggingface-cli download` command works on installations
predating `huggingface_hub` 0.27 but is deprecated.)

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

### Xcode requirement (Metal kernels)

MLX-swift's Metal kernels are compiled from `.metal` sources by SPM at
build time, which needs `xcrun metal` — that binary ships **only** with
the full Xcode.app (not with Command Line Tools). If you build under CLT
alone, the binary links but launching the predictor raises:

```
MLX error: Failed to load the default metallib. library not found ...
```

The C++ exception isn't catchable from Swift, so the whole process exits.
Workaround until Xcode is installed: do not place MLX weights in `Models/`
— `PredictorFactory.live()` will skip MLX init entirely and fall back to
the stub. Once Xcode is installed:

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
sudo xcodebuild -license accept
xcrun -find metal      # should print a path
rm -rf .build && ./Scripts/build.sh --with-brainflow
```

---

## 3. Why this split?

Core ML (ANE) for classification + MLX (GPU) for generation is the sweet spot
on Apple Silicon: the two engines don't fight for the same compute. Routing
the classifier to `.cpuAndNeuralEngine` is the load-bearing choice that keeps
the GPU free for MLX, and keeps the per-window classifier under ~3 ms even on
M1. Don't move it to `.all` unless you've profiled and confirmed it does not
contend with the LLM forward pass.
