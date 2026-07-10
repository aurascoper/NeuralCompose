# Session handoff — Phase B EEG fan-out + live Muse bring-up

Snapshot for continuing in Claude Code (which runs locally on the Mac and can
build, launch the app, drive BLE, and read the unified log — things the Cowork
session could not do from its sandbox).

## Verified working
- **Live Muse S streaming confirmed.** `--with-brainflow` build is green; the
  app connects to a real Muse S (`boardID=39`), `prepare_session status=0`,
  4 channels @ ~256 Hz steady for minutes. The earlier "synthetic / no signal"
  was a **stale stub binary**: `build.sh --with-brainflow` had been failing to
  compile, so `run-*.sh` relaunched the last good (stub) binary, and a stub
  bridge always resolves to synthetic. Fixed now.

## Commits this session (newest first)
- `34c886c` fix(phase-b): plotter subscribes when the stream first becomes available
- `7dba55e` chore(scripts): add golden-recording runner
- `9f21c38` fix(phase-b): compile the debug-window plotter stream wrapper (AsyncThrowingStream Never→any Error)
- `7309db5` test: unblock BCICoreTests/BCIEEGTests under Swift 6 strict concurrency
- `611879d` fix(eeg-stream): implement true multicast sample fan-out
- `a1b9a4b` feat(phase-b): wire channel-health provider into debug window
- `557c452` feat(health): per-channel RMS health classifier and provider

Working tree is clean except intentionally-untracked local files (CLAUDE.md,
requirements-calibration.txt, research artifacts). `Recordings/` is gitignored.

## Key architecture note
`AppViewModel.liveSampleStream()` is now backed by `AsyncMulticastChannel<EEGSample>`
(`Sources/BCICore/Buffers/`), a true one-to-many broadcast: every call returns
an independent subscriber that receives the full stream. The old code shared a
single `AsyncStream`, so the plotter and the health provider silently split the
samples ~50/50. Both consumers now get everything. `BoundedAsyncChannel` is
unchanged (single-consumer queue).

## Next steps (recommended order)
1. **Confirm the plotter fix on device.** Open Phase B (Cmd+Shift+D) on the live
   Muse and verify the trace renders *at the same time* as the health badges,
   and that a TP9 electrode lift turns only TP9 red while the plotter keeps
   drawing. This is the payoff of the multicast + plotter-subscription fixes and
   is the one thing not yet visually confirmed.
2. **Capture the golden recording.** `./Scripts/record-golden.sh` (Muse on, not
   connected to the Muse phone app). It narrates a timed protocol and writes
   `Recordings/golden/golden_<stamp>.csv` + a `.segments.csv` timeline. Enable
   Record in the app right when you press ENTER so CSV t≈0 aligns with the
   protocol.
3. **Run the unblocked tests.** `swift test` — `BCICoreTests`/`BCIEEGTests` now
   compile; confirm `AsyncMulticastChannelTests`, the rewritten
   `BoundedAsyncChannelTests.testTwoConsumersSplitTheStream`, and
   `FanOutHealthValidationTests` pass on a real toolchain.
4. **Wire the golden recording into the harness.** `FanOutHealthValidationTests`
   currently drives synthetic samples; swap the feed loop for `PlaybackEEGStream`
   pointed at the golden CSV, and slice by the `.segments.csv` to assert alpha
   rises during `eyes_closed_rest` and only TP9 goes dead during
   `tp9_electrode_lift`. That makes the whole broadcast+health contract a CI
   regression against real data.
5. Then proceed to the SceneKit workspace (drive it from the verified stream)
   before richer visualization (PCA/UMAP/connectivity).

## Gotchas confirmed this session
- Must build with `--with-brainflow`; a plain `build.sh` stub binary → synthetic.
  Check with `otool -L .build/debug/NeuralCompose | grep -i board` (should list
  `libBoardController`).
- Connect logs go to the unified log, not stdout:
  `log stream --predicate 'subsystem == "com.neuralcompose"' --level debug`.
- The MLX `Complex`/`Float16` notes during the build are harmless C-interop
  notes, not errors.
