# NeuralCompose

Privacy-first, fully on-device macOS prototype for **EEG-driven communication**. A Muse headband streams brain signals through BrainFlow, a Core ML classifier on the Apple Neural Engine detects intent (jaw clench / blink / rest / select), and a local MLX LLM suggests next words. The user "types" by letting a cycling 3-token carousel highlight a candidate, then committing with a brain-signal selection. **No network at runtime. No cloud. No telemetry.**

## Stack
- Swift 6.0, macOS 14+, SwiftPM (no Xcode project needed for the default build)
- Deps: `mlx-swift` (≥0.21.2), `mlx-swift-examples` (≥2.21.0), `swift-transformers` (≥0.1.20). **Linked only into `BCILLM`** — single MLX runtime in the linked binary.
- BrainFlow is **NOT** a SwiftPM dep — it's an optional system library via the `BCIBridge` Obj-C++ shim, gated by `BCI_BRAINFLOW_AVAILABLE`
- Strict concurrency on all targets; `ExistentialAny` upcoming feature enabled

## Run / test / build
```sh
./Scripts/build.sh                          # swift build (stub bridge, mock classifier, stub predictor)
./Scripts/run-synthetic.sh                  # launches app with synthetic EEG — no hardware, no models needed
./Scripts/build.sh --with-brainflow         # requires BrainFlow installed (see HARDWARE_SETUP.md)
./Scripts/run-muse-s.sh                     # live Muse S over Bluetooth
./Scripts/build-xcode-mlx.sh                # MLX path needs full Xcode (not just CLT) to compile Metal kernels
./Scripts/run-calibration.sh                # capture training data for intent classifier
python Scripts/train-intent-classifier.py   # train + export an .mlpackage from calibration data

swift test                                  # all tests
```

## Layout
- `Sources/BCIBridge/` — Obj-C++ shim for BrainFlow. Default builds with `BCI_BRIDGE_STUB`; define `BCI_BRAINFLOW_AVAILABLE` + `-lBrainflow` to wire in the real library.
- `Sources/BCICore/` — pure-Swift, no third-party deps: models, protocols (`EEGStreaming`, `IntentClassifying`, `NextWordPredicting`, `TokenizerProviding`), ring buffer, intent FSM
- `Sources/BCIEEG/` — EEG streams: BrainFlow facade, synthetic generator, playback from recordings
- `Sources/BCIClassifier/` — Core ML wrapper (ANE-preferred via `MLComputeUnits`); mock classifier for stub mode
- `Sources/BCILLM/` — **isolated MLX adapter** + stub predictor + tokenizer; ONLY target that imports MLX/transformers
- `Sources/NeuralComposeApp/` — SwiftUI app target; `AppContainer` composes everything via protocols
- `Models/` — `IntentClassifier.mlpackage` (auto-compiled by Core ML on first load), plus `README.md` for the MLX LLM drop-in convention
- `Tests/` — one test target per library (`BCICoreTests`, `BCIEEGTests`, `BCIClassifierTests`, `BCILLMTests`)
- `Scripts/` — build/run/calibration/training shell scripts + Python training helper
- `Recordings/` — captured EEG sessions for playback testing
- `WorldModel/` — **decoupled research spike** (PyTorch, not MLX; no dependency on `Sources/`): a synthetic JEPA + latent-MPC exercise, unrelated to the EEG pipeline until proven out — see its own `README.md`
- `HARDWARE_SETUP.md`, `MODEL_SETUP.md`, `CALIBRATION.md`, `TROUBLESHOOTING.md` — operational docs (keep up to date)

## Conventions
- **Composition root is `AppContainer`** — that's where dependency overrides for tests and the menu-bar UI live
- **App talks to subsystems through protocols only.** Never `import MLX` outside `BCILLM`.
- **MLX isolation is load-bearing.** Linking MLX into multiple targets duplicates the runtime — there's a Package.swift comment about it.
- Strict concurrency everywhere — `@Sendable`/actor discipline expected
- Stub-by-default: missing model → mock; missing weights → stub; bridge stub → synthetic EEG. The privacy banner reflects which path is active.
- At runtime, the supervisor retries live EEG up to 3× with exponential backoff before falling back to synthetic; banner shows "Reconnecting…" + signal-health badge from per-channel RMS

## Track B (imagined speech)
- **Experimental, not a production typing path.** Track A (jaw clench / blink / double blink / rest, cycling the carousel + dwell-select) is the only supported way to type. Track B (imagined-speech, closed-vocabulary) is a research arm with significant null-result risk — `Sources/NeuralComposeApp/ImaginedSpeechCalibrationView.swift` frames it accordingly in-app.
- **Hardware ceiling is real, not a tuning problem.** The Muse channel set (TP9, AF7, AF8, TP10) has nothing over Broca's area (~F7/F3) or left superior temporal gyrus (~T7/T3) — the regions covert-speech decoding relies on. AF7/AF8 are dominated by the ocular artifacts Track A exploits as a feature; imagined-speech work needs to suppress those instead. No published 4-channel dry-electrode Muse imagined-speech result clears a defensible chance bar.
- **Pre-registration gate (must pass before promoting past experimental):** a single binary held-out balanced-accuracy threshold — e.g. 65% on a 2-class discrimination, 5-fold within-subject cross-validation, n ≥ 50 trials per class — pinned *before* training. If it doesn't clear, Track B parks; do not promote on training accuracy or "looks promising."
- **Architecture isolation rule:** keep Track B's labels, classifier protocol, `.mlpackage`, and trainer parallel to Track A's, never extensions of them — mixing imagined-word labels into `CalibrationLabel`/`IntentClass` would corrupt the production model the next time `train-intent-classifier.py` runs against a mixed session.

## World Model (JEPA + MPC) research spike
- **Lives entirely in `WorldModel/`, decoupled from the app on purpose.** PyTorch, not MLX; no import of `BCICore`/`BCIEEG`/`BCIClassifier`/`BCILLM`. The MLX-isolation rule above doesn't apply here because nothing here touches the SwiftPM target graph.
- **Synthetic by design, not a shortcut.** The motivating idea — a JEPA-style transition predictor over EEG-derived `SpectralState`/`GenerationAdaptation` — is real but currently unbuildable: one processed night of sleep data, zero logged interaction events (`InteractionLogging` is opt-in, off by default per `ADR-005-local-interaction-logging.md`). A JEPA needs volume, action variation, and temporal transitions none of that provides yet. So the architecture gets proven on a synthetic 2D continuous-control task first, where ground truth and volume are both free.
- **Multi-day, staged.** Day 1 (synthetic env + trajectory dataset + DataLoader) is the only stage landed so far. See `WorldModel/README.md` for the full four-day plan and current status — don't assume later days exist without checking.
- **Pointing this at real EEG data is a future decision, not an assumption.** Nothing here should be read as committing to that path; it's contingent on the architecture actually working on the toy task first.

## Gotchas
- **MLX path requires full Xcode**, not just Command Line Tools — SwiftPM needs Xcode to compile mlx-swift's Metal kernels. See `MODEL_SETUP.md`. There's a parked `venv.py314.parked` from a Python 3.14 compatibility issue — current venv is regular Python.
- **`Info.plist` is intentionally not declared as a SwiftPM resource.** SwiftPM forbids top-level `Info.plist`. `swift run` works fine without it; an Xcode build picks it up.
- **`InternalImportsByDefault` is intentionally NOT enabled** — the friction with public Foundation-typed signatures wasn't worth it for an executable + 4 internal libraries.
- **Models are NOT in the repo.** Drop `IntentClassifier.mlmodelc` or `.mlpackage` into `Models/`; drop an MLX-converted LLM directory under `Models/<name>/`. Factories auto-detect at launch.
- **Synthetic mode is the canonical "it works" baseline** — if something breaks, fall back to `./Scripts/run-synthetic.sh` to localize whether it's the pipeline or a real component.
- `venv/` here is for the Python training helper only; nothing in the app touches it.
