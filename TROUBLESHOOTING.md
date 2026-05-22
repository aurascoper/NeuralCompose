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

### MLX runtime: "Failed to load the default metallib"

mlx-swift's Metal kernels are compiled by SPM during the Cmlx build using
`xcrun metal`, which ships only with full Xcode.app (not with Command
Line Tools). Confirm with `xcrun -find metal` — if it errors "not a
developer tool", that's the cause. Resolution:

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
sudo xcodebuild -license accept
xcodebuild -runFirstLaunch
rm -rf .build && ./Scripts/build.sh --with-brainflow
```

The matching Homebrew `mlx.metallib` does not work as a drop-in
(`/opt/homebrew/lib/mlx.metallib` is from `mlx` C++ 0.31.x; mlx-swift
0.25.6 vendors mlx 0.24.2, and the function specializations diverge —
`rope_single_float16` validation fails at first Metal call).

The same Xcode install also gets you `xcrun coremlcompiler` for
`.mlmodelc` compilation — see [MODEL_SETUP.md](MODEL_SETUP.md).

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

### Old recording (`labels.csv` is all "none", `eeg.csv` huge for short session)

Two compounding bugs in pre-v0.4.3 builds produced unusable
recordings. Both are fixed in current builds, but old session
directories still carry the broken artifacts:

- **Sample duplication.** The BrainFlow drain used `get_current_board_data`
  (peek-without-consume), so polling at 20 Hz re-yielded the same
  buffered samples ~80× before they aged out. An `eeg.csv` with
  1.5M rows for a 90 s session is the giveaway. Fixed in `1d4fb33`
  by switching to `get_board_data` + `get_board_data_count`.

- **Event/EEG epoch mismatch.** Event timestamps were written via
  `timeIntervalSinceReferenceDate` (seconds since 2001) while EEG
  samples carry BrainFlow's `timeIntervalSince1970` (Unix epoch). The
  978307200 s offset meant no event ever overlapped any window, so
  `labels.csv` came out uniformly "none". Fixed by switching the
  event writers to `timeIntervalSince1970`.

`Scripts/train-intent-classifier.py` auto-detects the epoch offset and
re-derives labels from `events.csv` directly, so a pre-fix session with
real EEG and real events can still train without re-recording — as
long as both actually cover the same wall-clock window.

### Sticky-label events (`rest`, `jaw_clench`, `artifact`) absent from `labels.csv`

Pre-v0.4.4: `startStickyLabel` pushed a struct copy into both an
`activeEvents` and `allEvents` array. When `endStickyLabel` updated
the duration, only `activeEvents` saw it — `allEvents` (the writer
source for `events.csv`) kept the original zero-duration record. Every
sticky press was therefore a single-instant event that never made the
50 % overlap threshold during label resolution. Fixed in `e54d9f6`;
re-record to get usable rest/clench/artifact labels.

### Muse keeps disconnecting / "Reconnecting…" stays up

The Muse S auto-powers-off after ~30 s of poor scalp contact, looking to
the BrainFlow stream like a clean completion. Since v0.4.1 the supervisor
retries the live source 3 times with exponential backoff (1 s / 2 s / 4 s)
before falling back to synthetic — that's the "Reconnecting…" banner state.
If it never recovers to "Live pipeline":

- **Signal-health badge stays red.** Re-wet the pad and the two ear
  electrodes; dry pads are the most common cause.
- **Muse battery low.** A drained Muse will reconnect briefly and drop
  again within seconds. There is no battery readout for the non-Athena
  Muse S — BrainFlow doesn't expose it (only board id 67 / Athena has a
  `battery_channel`). Charge the headset.
- **Another app holds the BLE connection.** Quit Muse Direct / Mind
  Monitor; only one app can own the Muse at a time.

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
