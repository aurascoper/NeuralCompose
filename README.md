# NeuralCompose

A privacy-first, fully on-device macOS prototype for **EEG-driven communication**:
a Muse headband streams brain signals through BrainFlow, a small Core ML
classifier on the **Apple Neural Engine** detects intent (jaw clench / blink /
rest / select), and a **local MLX LLM** suggests the next word. The user
"types" by letting a cycling 3-token carousel highlight a candidate, then
committing it with a brain-signal selection.

No cloud APIs. No telemetry. No network at runtime.

```
 Muse EEG ──▶ BrainFlow ──▶ ring buffer ──▶ window + filter
                                                 │
                                                 ▼
                                          Core ML (ANE)
                                                 │
                                                 ▼
                                          Intent smoother ──▶ FSM
                                                                │
                                                                ▼ (select)
                                                          Carousel commits
                                                                │
                                                                ▼
                                                    MLX LLM next-word
                                                                │
                                                                ▼
                                                          SwiftUI carousel
```

## Quick start (synthetic mode — no hardware, no models)

```bash
git clone <your fork>
cd NeuralCompose
./Scripts/build.sh        # swift build
./Scripts/run-synthetic.sh
```

The app launches, generates a synthetic EEG stream, exercises the full pipeline
through the mock Core ML classifier and the stub next-word predictor, and you
can immediately see the carousel cycle and commit tokens. Everything works
**without** a Muse, without an `.mlmodelc`, and without local model weights.

## Switching on real components

| Component         | Enable by                                                            |
|-------------------|----------------------------------------------------------------------|
| Muse via BrainFlow | Install BrainFlow C++ libs, rebuild with `-D BCI_BRAINFLOW_AVAILABLE`. See [HARDWARE_SETUP.md](HARDWARE_SETUP.md). |
| Real Core ML model | Drop a compiled `.mlmodelc` into `Models/IntentClassifier.mlmodelc` and toggle "Use Core ML" in the UI. |
| Real MLX LLM       | Drop a converted MLX model into `Models/<name>/` and toggle "Use MLX" in the UI. See [MODEL_SETUP.md](MODEL_SETUP.md). |

If something is missing at **launch** (no `.mlmodelc`, no MLX weights, bridge
in stub mode) the factory wires up the mock / stub equivalent and the privacy
banner reflects it. At **runtime**, if the live EEG stream errors or
disconnects, `AppViewModel`'s supervisor swaps in the synthetic stream and
updates the banner to degraded mode — the session does not crash and never
reaches the network. We do not auto-reconnect to the same device; restart the
app (or call `viewModel.stop()` then `start()`) to retry the live stream.

## Architecture in one paragraph

`BCICore` defines every protocol the app talks to: `EEGStreaming`,
`IntentClassifying`, `NextWordPredicting`, `TokenizerProviding`. `BCIEEG`,
`BCIClassifier`, and `BCILLM` each provide concrete implementations behind
those protocols. **MLX-Swift and swift-transformers are linked only into
`BCILLM`** — the app target talks to it through `NextWordPredicting`, so there
is exactly one MLX runtime copy in the binary and no duplicate-symbol risk. The
app composes everything in `AppContainer`, which is also where dependency
overrides for testing and for the menu-bar UI live.

## Repository layout

```
Sources/
  BCIBridge/        Obj-C++ shim for BrainFlow (stub by default)
  BCICore/          pure-Swift models, protocols, FSMs, buffers
  BCIEEG/           EEG streams (BrainFlow / synthetic / playback)
  BCIClassifier/    Core ML wrapper + mock
  BCILLM/           MLX adapter + stub + tokenizer    ← only MLX target
  NeuralComposeApp/ SwiftUI window + menu-bar UI
Tests/              unit tests, all passable in synthetic mode
Scripts/            build / run / profile helpers
Models/             where you drop .mlmodelc and MLX weight folders
```

## Privacy posture

- No outbound network calls during normal operation. `swift-transformers` is
  used **only** for local tokenizer/template utilities; no Hub access at runtime.
- Recorded EEG never leaves the machine. `Recordings/` is gitignored.
- The UI always shows a privacy indicator: which signal source is active,
  which classifier, and which predictor — and whether each is real or stub.

## Documentation

- [HARDWARE_SETUP.md](HARDWARE_SETUP.md) — Muse + BrainFlow + Bluetooth dongle.
- [MODEL_SETUP.md](MODEL_SETUP.md)   — Core ML and MLX model files.
- [TROUBLESHOOTING.md](TROUBLESHOOTING.md) — common build / runtime issues.

## License

This is research prototype code. Do not use NeuralCompose to make clinical or
safety-critical decisions.
