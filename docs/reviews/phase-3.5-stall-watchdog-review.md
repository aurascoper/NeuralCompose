# Review: Phase 3.5 (stall watchdog + channel health staleness)

Branch: `claude/competent-robinson-ddf10c` (in `.claude/worktrees/competent-robinson-ddf10c/`)
Base: `3dfee9f` (random-projection embedding commit on `main`)
Head: working tree, 7 files modified, 2 new test files, +216/-20

**Verdict: ship it, with three pre-merge touch-ups.** The bug fix is real and well-characterized, the design intent is testable and tested, and the new test target is correctly scoped. Items below are split into "fix before merge" (3) and "follow-up issues" (4).

---

## What this change does

The headline fix is the stall watchdog in `AppViewModel.nextOrStall`. A silent BLE death (bluetoothd drops the link; BrainFlow's `drain_samples` keeps returning `BCI_OK` with zero samples forever) never throws and never finishes the `AsyncThrowingStream`. The old `for try await sample in stream` loop suspended indefinitely, making the supervisor's retry/backoff path unreachable in that case. This change bounds each `next()` with a 5-second timeout, throws `BCIError.streamFailed` on timeout, and lets the existing error-handling path drive the retry.

The supporting change is the `lastSampleWallClock` field on `ChannelHealthState`, which gives the UI a real-time staleness signal independent of the stream-relative `EEGSample.timestamp` (which starts at 0 for synthetic and playback sources, so reusing it for staleness would make every badge read as permanently stale in those modes). The badge now dims and shows "no data Ns" in orange when 2+ seconds have passed since the last real sample.

---

## Fix before merge

### 1. Document `CancellationError` propagation in `nextOrStall`

`Sources/NeuralComposeApp/AppViewModel.swift`, in `nextOrStall` (around line 657).

If the parent `Task` is cancelled while `next()` is suspended, `AsyncThrowingStream.next()` throws `CancellationError`. That propagates up to the supervisor's `do/catch`, which currently classifies it as a stream failure and increments the retry counter. That's probably fine, but a future reader adding a `catch is CancellationError` here would double-handle it and silently break cancellation.

Add one line to the `nextOrStall` doc comment:

```swift
/// `CancellationError` is intentionally not handled here: it propagates to
/// the supervisor's `catch`, which classifies it as a stream failure. The
/// outer `while !Task.isCancelled` then exits the retry loop on the next
/// iteration. Don't add a `catch is CancellationError` here — that would
/// double-handle cancellation and break the supervisor's exit path.
```

### 2. Make the stall timeout overridable for tests

`Sources/NeuralComposeApp/AppViewModel.swift`, around line 195 where `staleStreamTimeout` is declared as a `let` inside the supervisor closure.

Currently:

```swift
let staleStreamTimeout: TimeInterval = 5.0
```

Make it a `nonisolated static let` on `AppViewModel` (or a value on a new `AppViewModel.Config` struct) so a future test can assert the supervisor detects a stall in a shorter window without waiting the full 5s. The existing 8-second integration test would still pass, but a follow-up "supervisor detects stall in 1.5s with a 1s timeout" test would be straightforward.

Suggested change:

```swift
nonisolated static let defaultStaleStreamTimeout: TimeInterval = 5.0
```

And in the supervisor:

```swift
let staleStreamTimeout = Self.defaultStaleStreamTimeout
```

If a `Config` struct lands for other reasons, fold it in then. Don't introduce one solely for this.

### 3. Note the Xcode requirement on the new test target

`Tests/NeuralComposeAppTests/AppViewModelStallRecoveryTests.swift`, top of file.

The test calls `PredictorFactory.live()`, which goes through the real MLX path. That means this test target can only build and run in an environment with full Xcode installed, not just Command Line Tools — same constraint as the rest of `BCILLM`. Add a one-line comment at the top of the test file:

```swift
// Build/run requires full Xcode (not just CLT) — the test instantiates
// AppViewModel with a real PredictorFactory.live(), which links MLX.
```

A future CI contributor running `swift test` on Linux or CLT-only macOS will hit a confusing linker error otherwise. The new test target's `Package.swift` entry doesn't make this obvious because all the dependencies are listed, but the actual constraint is on the MLX build.

---

## Follow-ups (file as issues, don't block merge)

### F1. Test that the supervisor gives up after `maxLiveRetries`

`Tests/NeuralComposeAppTests/AppViewModelStallRecoveryTests.swift`.

The current test asserts `startCallCount >= 2` (i.e., the supervisor detected the stall and reconnected at least once). It does not assert the upper bound. The fallback-to-synthetic behavior after `maxLiveRetries` is the whole point of the retry path; it deserves its own test.

Add `testSupervisorGivesUpAfterMaxLiveRetriesAndFallsBackToSynthetic`:

- `StallingEEGStream` that never recovers (the existing one is fine).
- Assert `startCallCount == 1 + maxLiveRetries` (initial attempt + 3 retries).
- Assert the `PipelineMode` snapshot shows `source == .synthetic` (or whatever the fallback is — check the supervisor's catch-all path).

This catches regressions where someone bumps `maxLiveRetries` accidentally or breaks the fallback path.

### F2. Test that the badge `isStale` flag flips within a render of the stream going silent

The current test coverage is:

- Unit: `lastSampleWallClock` advances on ingest and freezes when silent.
- Integration: supervisor reconnects after a stall.

Missing: the link between the two — does the badge actually update in response to the wall-clock field changing? This is the part a user sees.

A targeted test could:

- Create a `ChannelHealthBadge` with a `state` whose `lastSampleWallClock = now - 3.0` and `samples = 100`.
- Assert the rendered output contains "no data 3s" (or similar).
- Re-render with `now: now + 1.0`.
- Assert the output now contains "no data 4s".

This is a SwiftUI view test, so it goes in the same `NeuralComposeAppTests` target.

### F3. Add a test-fixture factory for `EEGStreaming` instances

`Tests/BCIEEGTests/` (or a new `Tests/BCIEEGTests/Fixtures/`).

The new test reaches into `EEGStreamFactory.Resolved.init` directly to inject a `StallingEEGStream`. That's a hint there's no test-side factory for `EEGStreaming` instances. A `EEGStreamFactory.fake(_:)` (or a `FakeEEGStreamBuilder` in the test target) would let future tests inject streams without depending on the new public initializer, and would let the public initializer go back to internal access once tests don't need it.

Not urgent. File as a "test infrastructure" follow-up.

### F4. Tighten the doc on the public `Resolved.init`

`Sources/BCIEEG/EEGStreamFactory.swift`.

The new public initializer's doc comment says "Public so tests (and previews) can wrap an arbitrary `EEGStreaming`..." That's correct but undersells the convention. A future reader might think it's a normal API entry point and use it from production code, bypassing `EEGStreamFactory.make(profile:)`.

Add a stronger header line:

```swift
/// **Test/preview injection point.** Production code constructs `Resolved`
/// exclusively via `make(profile:)` — this initializer exists so the test
/// suite (and SwiftUI previews) can wrap an arbitrary `EEGStreaming`
/// (e.g. a `StallingEEGStream` that simulates a dead BLE session) without
/// going through the factory's hardware-discovery path. If you're calling
/// this from production code, stop and use `make(profile:)` instead.
```

---

## What I'd not change

- The `StreamIteratorBox` `@unchecked Sendable` is the right escape hatch. The "only ever awaited from one call site at a time" invariant is documented and accurate; the alternative (making `EEGStreaming` an actor) would ripple through the codebase for no real safety win. Keep as-is.
- The 5-second stall timeout is reasonable for now. A real production tuning pass might want 2-3 seconds, but with the current BLE/wifi reliability on macOS that's probably too aggressive. 5s is the right default for a "first cut."
- The "no data Ns" indicator is the right UX choice. Orange + dim + "samples > 0" gate is the correct combination to distinguish "never connected" from "was connected, now silent."
- The new `NeuralComposeAppTests` test target is the right scope. `NeuralComposeApp` is an executable, not a library, and the standard SwiftPM pattern for testing executables is exactly what this does.

---

## Suggested merge commit message

```
fix(supervisor): detect stream stalls with bounded per-sample timeout

A silent BLE death (bluetoothd drops the link; BrainFlow's drain loop
keeps returning BCI_OK with zero samples forever) never throws and never
finishes its AsyncThrowingStream. The old `for try await sample in stream`
loop in the supervisor suspended indefinitely, making the retry/backoff
path unreachable in that case.

Fix: race each `next()` against a 5-second timeout. On timeout, throw
BCIError.streamFailed so the existing error-handling path drives the
retry. StreamIteratorBox is the reference wrapper that lets the race
cross the concurrency boundary.

UI side: ChannelHealthState gains a `lastSampleWallClock` field,
distinct from the stream-relative `timestamp` (which starts at 0 for
synthetic/playback sources and would otherwise read as permanently
stale). ChannelHealthBadge shows "no data Ns" in orange when 2+ seconds
have passed since the last real sample, distinguishing "never connected"
from "was live, then stopped."

Tests: new NeuralComposeAppTests target exercises a StallingEEGStream
fake to prove the supervisor reconnects after a stall. Unit test on
EEGChannelHealthProvider asserts the wall-clock field advances on
ingest and freezes when the stream goes silent.

Reviewed-by: MiniMax <hkinder@stlteach.org>
```

---

## Files reviewed

- `Sources/BCICore/Models/ChannelHealthState.swift` (modified)
- `Sources/BCIEEG/EEGChannelHealthProvider.swift` (modified)
- `Sources/BCIEEG/EEGStreamFactory.swift` (modified)
- `Sources/NeuralComposeApp/AppViewModel.swift` (modified)
- `Sources/NeuralComposeApp/SleepValidationView.swift` (modified)
- `Tests/BCIEEGTests/EEGChannelHealthProviderTests.swift` (modified)
- `Tests/NeuralComposeAppTests/AppViewModelStallRecoveryTests.swift` (new)
- `Tests/NeuralComposeAppTests/StallingEEGStream.swift` (new)
- `Package.swift` (modified, test target addition)
