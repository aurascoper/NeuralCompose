# Troubleshooting

## Build

### `swift build` hangs / fails on first run

It's almost always fetching `mlx-swift` and `mlx-swift-examples`, both of which
are large. Make sure you have network on the first build. Once
`Package.resolved` exists, subsequent builds are offline.

If a package fails to resolve because of an API drift in a new release, pin a
known-good revision in `Package.swift`:

```swift
.package(url: "...", revision: "<known good sha>"),
```

The `MLXNextWordPredictor` adapter intentionally lives behind a protocol so a
breaking MLX release does not touch any other file.

### "Duplicate symbols for MLX"

This is the failure mode that motivated the module split. If you see it, the
fix is always the same: a target other than `BCILLM` has acquired a `.product(name: "MLX*", ...)`
dependency. Remove it. The only target that may link MLX is `BCILLM`.

### `BCI_BRAINFLOW_AVAILABLE` defined but compiler can't find headers

You need to point the SwiftPM C++ build at your BrainFlow install:

```bash
swift build \
  -Xcc -DBCI_BRAINFLOW_AVAILABLE=1 \
  -Xcc -I/opt/homebrew/include \
  -Xlinker -L/opt/homebrew/lib \
  -Xlinker -lBrainflow
```

`Scripts/build.sh --with-brainflow` does this for you.

### Strict concurrency warnings

The package is built with strict concurrency on. Most warnings are real —
treat them as compile errors. If you must silence one temporarily, prefer
`@preconcurrency import` to `nonisolated(unsafe)`.

## Runtime

### "Classifier never fires an intent"

By default the synthetic stream is intentionally near-zero amplitude. The
`MockIntentClassifier` will only emit non-rest intents when EEG energy clears a
threshold. Either:

- Increase synthetic amplitude in `SyntheticEEGStreamConfig.amplitude`, or
- Enable the demo mode toggle in the app — it nudges synthetic energy through
  the intent thresholds on a fixed schedule so you can see end-to-end behavior.

### LLM predictor is super slow

You are probably running an MLX model too large for your machine, or the
Core ML classifier is set to `.all` and contending with MLX for GPU. Fixes:

- Pick a smaller MLX model (4-bit 0.5B–1.5B for M1, up to 3B for M2/M3/M4).
- Make sure classifier compute mode is `.cpuAndNeuralEngine` in the UI.
- Profile with `Scripts/profile.sh` — it captures classifier and predictor
  latency separately.

### The privacy banner shows degraded mode unexpectedly

Click on it. It expands and tells you exactly which substitution happened
(synthetic stream / mock classifier / stub predictor) and why. The most
common reason is that the corresponding `Models/` file is missing.

### App quits the moment I unplug Bluetooth

It shouldn't — `BrainFlowService` catches the disconnect and emits a single
`BCIError.streamFailed`, after which the app swaps in the synthetic stream.
If you see a hard crash, capture the stack trace, the BrainFlow board profile,
and the dongle model, and file an issue.

## Tests

### `swift test` errors with `no such module 'XCTest'`

You have only the Command Line Tools installed, not full Xcode. `XCTest.framework`
ships with Xcode, not the CLT bundle, so `/usr/bin/swift test` and
`/Library/Developer/CommandLineTools/usr/bin/swift test` both fail. Install Xcode
from the App Store, then:

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
swift test
```

`swift build` does **not** require Xcode and works under CLT alone — that's
why the demo runs in CLT-only environments but the test suite does not.

### `swift test` says no tests ran for a target

The four test targets each gate themselves on environment availability. For
example, `BCIClassifierTests` skips Core ML tests if no model file is
present. That is the documented behavior — read the SKIP message at the top
of each test bundle to know what to install if you want full coverage.
