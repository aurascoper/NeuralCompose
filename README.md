# NeuralCompose

NeuralCompose is a privacy-oriented macOS research prototype for EEG-driven communication, signal visualization, semantic composition, and sleep-cycle experimentation.

A Muse headband can feed four-channel EEG into a Swift pipeline for acquisition, windowing, signal-quality checks, intent classification, semantic visualization, text generation, and speech. The repository also includes deterministic synthetic and playback modes, offline evaluation tools, and experimental dialectical dialogue loops.

> **Research prototype:** NeuralCompose is not a medical device and must not be used for diagnosis, treatment, safety-critical communication, or clinical decisions.

## What runs where

| Component | Default location |
|---|---|
| SwiftUI application and visualization | Mac |
| EEG acquisition and preprocessing | Mac |
| Core ML classifiers and embeddings | Mac / Apple Neural Engine when available |
| MLX models | Mac / Apple Silicon GPU when configured |
| Ollama generation | Configured Ollama server, commonly the same Mac |
| Claude generation | Anthropic through the locally installed Claude Code CLI |
| Interaction logs and research artifacts | Local filesystem |

Most of the application can run without hardware, model weights, Ollama, Claude, or BrainFlow. The synthetic stream and deterministic fallbacks are the recommended first launch.

Cloud generation is opt-in. Selecting the Claude runtime sends prompt text through the authenticated Claude Code CLI. NeuralCompose records the requested and resolved runtime identity so local and cloud execution are not presented as interchangeable.

## Live signal

<p align="center">
  <img src="Recordings/golden/report/raw_traces.png" width="49%" alt="Four-channel EEG traces from the golden recording">
  <img src="Recordings/golden/report/3d-workspace.png" width="49%" alt="NeuralCompose 3D workspace">
</p>

The committed golden recording contains TP9, AF7, AF8, and TP10 data from a Muse S. It supports deterministic regression tests of playback, windowing, feature extraction, channel health, and visualization behavior. See [`Recordings/golden/README.md`](Recordings/golden/README.md).

## Requirements

### Minimum local build

- macOS 14 or newer
- Apple Silicon recommended
- Git
- Swift 6 toolchain
- Xcode Command Line Tools

Install the command-line tools when necessary:

```bash
xcode-select --install
```

Confirm the toolchain:

```bash
swift --version
xcode-select -p
```

### Full local feature build

Install the full Xcode application when using MLX GPU execution, Metal kernels, app signing, or Xcode-based builds.

After installing Xcode:

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
sudo xcodebuild -license accept
xcodebuild -version
```

Optional external systems:

- **BrainFlow** for direct Muse acquisition
- **Ollama** for local HTTP generation
- **Claude Code CLI** for the opt-in Anthropic runtime
- Converted Core ML and MLX model artifacts under `Models/`

## Clone

```bash
git clone https://github.com/aurascoper/NeuralCompose.git
cd NeuralCompose
```

The commands below assume the repository root is the current directory.

## Fastest local launch: synthetic mode

Synthetic mode needs no Muse, BrainFlow installation, external model weights, Ollama daemon, or Claude login.

```bash
./Scripts/build.sh
./Scripts/run-synthetic.sh
```

`run-synthetic.sh` launches the SwiftPM executable with:

```text
NEURALCOMPOSE_BOARD_PROFILE=synthetic
```

You can also launch it directly:

```bash
NEURALCOMPOSE_BOARD_PROFILE=synthetic \
  swift run -c debug NeuralCompose
```

## Build commands

### Debug

```bash
./Scripts/build.sh
```

Equivalent SwiftPM command:

```bash
swift build -c debug
```

Bare executable:

```bash
.build/debug/NeuralCompose
```

### Release

```bash
./Scripts/build.sh --release
```

Bare executable:

```bash
.build/release/NeuralCompose
```

### Clean rebuild

```bash
swift package clean
rm -rf .build
./Scripts/build.sh
```

Removing `.build` also removes cached dependencies and packaged application bundles, so the next build takes longer.

## Build a launchable macOS application bundle

A bare SwiftPM executable is sufficient for synthetic development. Bluetooth, microphone, and speech-recognition paths should run through the packaged `.app`, because macOS privacy services read their usage descriptions from the bundle’s `Info.plist`.

Build and package a debug application:

```bash
./Scripts/build.sh
./Scripts/package-app-bundle.sh
```

The resulting executable is:

```bash
APP_BIN="$PWD/.build/NeuralCompose.app/Contents/MacOS/NeuralCompose"
```

Verify it:

```bash
test -x "$APP_BIN" && echo "NeuralCompose app executable is ready"
codesign --verify --deep --strict "$PWD/.build/NeuralCompose.app"
```

Launch the packaged app directly so environment variables reach the process:

```bash
NEURALCOMPOSE_BOARD_PROFILE=synthetic "$APP_BIN"
```

Do not use `open NeuralCompose.app` when testing environment-selected runtimes; Launch Services does not reliably preserve shell environment variables.

### Release application bundle

```bash
./Scripts/build.sh --release
./Scripts/package-app-bundle.sh --release

APP_BIN="$PWD/.build/NeuralCompose.app/Contents/MacOS/NeuralCompose"
"$APP_BIN"
```

The packaging script applies an ad-hoc signature. Distribution outside the development Mac requires an Apple Developer signing, notarization, and release workflow that is not provided by the local script.

## Select a generation runtime

Set `APP_BIN` after packaging:

```bash
APP_BIN="$PWD/.build/NeuralCompose.app/Contents/MacOS/NeuralCompose"
```

### Claude through Claude Code

Prerequisites:

```bash
claude --version
claude login
```

Launch:

```bash
env \
  NEURALCOMPOSE_RUNTIME=claude \
  NEURALCOMPOSE_MODEL=claude-sonnet-5 \
  "$APP_BIN"
```

This is a cloud path. The executable is local, but generation is brokered through the authenticated Claude Code service. If Claude is configured but cannot generate, the runtime fails closed rather than silently switching providers.

### Ollama

Install and start Ollama using its normal macOS installation, then pull the requested model:

```bash
ollama pull qwen2.5:0.5b
ollama list
```

Launch:

```bash
env \
  NEURALCOMPOSE_RUNTIME=ollama \
  NEURALCOMPOSE_MODEL=qwen2.5:0.5b \
  "$APP_BIN"
```

The runtime performs a bounded readiness check and requires the requested model to be available. A missing model disables the loop; it does not substitute Claude.

### Runtime troubleshooting

Check the executable and dependencies first:

```bash
printf 'APP_BIN=%s\n' "$APP_BIN"
test -x "$APP_BIN"
claude --version 2>/dev/null || true
ollama list 2>/dev/null || true
```

Run the packaged process from a terminal to retain stderr and structured runtime diagnostics.

## MLX and Metal kernels

The ordinary SwiftPM build is sufficient for synthetic mode, deterministic tests, stub predictors, and most development. A real MLX GPU path needs Metal shaders compiled by the full Xcode toolchain.

Build with Xcode:

```bash
./Scripts/build-xcode-mlx.sh
```

Build and run the MLX smoke path:

```bash
./Scripts/build-xcode-mlx.sh --smoke
```

Release configuration:

```bash
./Scripts/build-xcode-mlx.sh --release
```

The script writes Xcode products under:

```text
.build/xcode/Build/Products/
```

After an Xcode MLX build, package the normal SwiftPM app again when you need `.build/NeuralCompose.app`. `package-app-bundle.sh` searches the Xcode products for `mlx-swift_Cmlx.bundle` and includes it when a compiled `default.metallib` is available.

If packaging reports:

```text
no mlx-swift_Cmlx.bundle with a metallib found
```

the app still launches, but the affected MLX spectral path falls back to its stub.

## Muse and BrainFlow

The default build compiles the BrainFlow bridge in stub mode. Direct Muse acquisition requires a compatible BrainFlow checkout or installation.

The build script searches in this order:

1. `--brainflow-path=<path>`
2. `~/Developer/brainflow`
3. `brew --prefix brainflow`

Example:

```bash
./Scripts/build.sh \
  --with-brainflow \
  --brainflow-path="$HOME/Developer/brainflow"

./Scripts/package-app-bundle.sh
APP_BIN="$PWD/.build/NeuralCompose.app/Contents/MacOS/NeuralCompose"
```

Launch the provided Muse script when its assumptions match your installation:

```bash
./Scripts/run-muse-s.sh
```

Bluetooth access must be granted to the packaged application. A bare executable can be terminated by macOS privacy enforcement before the application can surface a normal error.

See [`HARDWARE_SETUP.md`](HARDWARE_SETUP.md) for board setup and [`TROUBLESHOOTING.md`](TROUBLESHOOTING.md) for acquisition failures.

## Playback

Launch a recorded session through the playback profile:

```bash
./Scripts/run-synthetic.sh \
  --profile playback \
  --recording Recordings/golden/golden_20260710-141352.eeg.csv
```

Analyze the golden recording:

```bash
python3 Scripts/analyze-eeg-session.py \
  Recordings/golden/golden_20260710-141352.eeg.csv
```

## Tests

Run all Swift tests:

```bash
swift test
```

Run the deterministic golden-recording regression:

```bash
swift test --filter GoldenRecordingRegressionTests
```

Run app/runtime-focused suites:

```bash
swift test --filter NeuralComposeAppTests
swift test --filter BCICloudBridgeTests
swift test --filter DialecticSessionTests
```

List discovered tests when validating CI filters:

```bash
swift test list
```

Run repository Python contracts when their dependencies are installed:

```bash
python3 -m pytest -q Tests/eval
python3 -m unittest discover -s NeuralComposeEEG/tests -t .
```

Before committing:

```bash
git diff --check
swift build
```

Some MLX, Core ML, live network, hardware, and operator-attended tests are intentionally environment-dependent. A green deterministic suite does not prove Muse connectivity, provider authentication, microphone authorization, or real model execution.

## Useful environment variables

| Variable | Purpose |
|---|---|
| `NEURALCOMPOSE_BOARD_PROFILE` | Selects `synthetic`, playback, OSC, or a supported live board profile |
| `NEURALCOMPOSE_PLAYBACK_PATH` | Recording used by playback mode |
| `NEURALCOMPOSE_RUNTIME` | Selects generation runtime, currently `claude` or `ollama` on the packaged runtime path |
| `NEURALCOMPOSE_MODEL` | Requested model identity |
| `NEURALCOMPOSE_INTERACTION_LOG` | Enables opt-in local interaction logging when supported by the selected path |

Environment variables configure a launch; they are not durable application preferences. Start a new process after changing them.

## Architecture

```text
NeuralComposeApp
  ├── BCICore          pure-Swift models, protocols, actors, FSMs, buffers
  ├── BCIEEG           synthetic, playback, OSC, BrainFlow, health, visualization
  ├── BCIClassifier    Core ML classifier and sentence-embedding implementations
  ├── BCILLM           isolated MLX runtime and deterministic fallbacks
  ├── BCIVoice         speech recognition and synthesis seams
  ├── BCICloudBridge   explicit opt-in generation egress
  └── WorldModelDemo   synthetic-task research demo, separate from live EEG claims
```

Load-bearing boundaries:

- `BCICore` owns portable interfaces and deterministic mechanisms.
- MLX imports are isolated to `BCILLM`.
- Cloud generation is isolated to `BCICloudBridge`.
- The interface consumes resolved runtime and pipeline state rather than inventing provider or locality claims.
- Synthetic research demos do not imply validation on physical EEG.

See:

- [`docs/Architecture.md`](docs/Architecture.md)
- [`docs/architecture/PRINCIPLES.md`](docs/architecture/PRINCIPLES.md)
- [`docs/architecture/decision-log/`](docs/architecture/decision-log/)
- [`docs/Math.md`](docs/Math.md)
- [`docs/Research.md`](docs/Research.md)

## Repository layout

```text
NeuralCompose/
├── Sources/
│   ├── BCIBridge/
│   ├── BCICore/
│   ├── BCIEEG/
│   ├── BCIClassifier/
│   ├── BCILLM/
│   ├── BCIVoice/
│   ├── BCICloudBridge/
│   ├── NeuralComposeApp/
│   ├── DialecticSession/
│   └── WorldModelDemo/
├── Tests/
├── Scripts/
├── NeuralComposeEEG/
├── Evaluation/
├── Recordings/
├── Models/
├── WorldModel/
├── docs/
└── paper/
```

## Current evidence boundary

Established engineering capabilities include deterministic playback, synthetic-mode operation, local pipeline instrumentation, real Muse recording workflows, Core ML integration, and runtime provenance mechanisms.

The following remain research questions or environment-dependent capabilities:

- reliable decoding of intended communication from consumer EEG;
- research-grade sleep staging from four Muse channels;
- sustained behavioral differences among dialogue profiles;
- cognitive-incubation or dream-analysis benefits;
- generalization of synthetic world-model findings to physical EEG;
- production-quality accessibility or medical use.

Documentation and telemetry should preserve the difference between an implemented pipeline, a successful local run, and scientific evidence.

## Additional documentation

- [`HARDWARE_SETUP.md`](HARDWARE_SETUP.md)
- [`MODEL_SETUP.md`](MODEL_SETUP.md)
- [`CALIBRATION.md`](CALIBRATION.md)
- [`TROUBLESHOOTING.md`](TROUBLESHOOTING.md)
- [`SLEEP_CYCLE_DESIGN.md`](SLEEP_CYCLE_DESIGN.md)
- [`Recordings/golden/README.md`](Recordings/golden/README.md)

## Citation

A paper draft is available under `paper/`. Suggested citation when published:

> Kinder, H. (2026). *An open-source, privacy-preserving platform for EEG-guided cognitive incubation and dream-report analysis using consumer-grade hardware.* In preparation.

## License

MIT. See [`LICENSE`](LICENSE).

Research prototype code. Do not use NeuralCompose to make clinical or safety-critical decisions.

## Acknowledgements

- BrainFlow for the unified biosensor acquisition API
- MLX-Swift for Apple Silicon model execution
- Apple Core ML and the Neural Engine
- The Muse developer community
- Open-source EEG and sleep-research communities
