# NeuralCompose — Deep Code Review (2026-07-19)

Multi-agent review across five lenses: privacy/security, Swift 6 concurrency, architecture, repo hygiene/process, and correctness. Read-only; no code was changed. Branch under review: `feature/spoken-generation-loop` (15 commits ahead of origin).

## Verdict

This is a strong, unusually well-governed research codebase — the no-network privacy invariant genuinely holds, the layering is deliberate and mostly clean, the golden-recording regression is real, and the code is nearly free of TODOs, `fatalError`, and silent fallbacks. The problems cluster in three places: **one Critical concurrency bug on the real-hardware EEG teardown path**, a **process gap** (no CI, ~12 MB of stray artifacts, unpushed single-copy work), and **one god-object** (`AppViewModel`, 1,383 LOC) that drags several smaller smells behind it. The live intent→text path is sound apart from a numerically-unstable softmax; the research arms (Track B, sleep-viz, hypnagogic, WorldModel) carry heavier, appropriately-experimental issues.

Fix the Critical first, push your work, then attack the god-object and CI.

---

## CRITICAL

### C1 — Use-after-free: BrainFlow C++ session `delete`d during a concurrent drain
`Sources/BCIEEG/BrainFlowService.swift:112-118, 161-180`; C side `Sources/BCIBridge/BCIBridge.mm:205-289` vs `:307-317`

The poll task reads the handle under `lock` (`:113`) but calls `bci_bridge_drain_samples(handle, …)` **outside** the lock (`:118`). `stop()` nils the handle under the same lock, then calls `stop_stream` + `destroy_session` (→ `delete handle`) **outside** it (`:176-179`). The lock protects the pointer, not the C++ session's lifetime across the drain. On teardown, `continuation.onTermination` spawns `Task { await self?.stop() }` (`:163`) which can `delete` the board while the poll task is still inside `get_board_data(...)` dereferencing `handle->boardId/eegChannels/paramsJson`. On real hardware this is a use-after-free / concurrent BrainFlow-API violation (crash or corruption), not a benign race. Compounded by a redundant second `stop()` from `AppViewModel.swift:569`.

**Fix:** make teardown structured — `stop()` (and `onTermination`) should `cancel()` then `await pollTask?.value`, and let the poll task itself perform `stop_stream`/`destroy_session` when its loop exits, so drain and destroy can never overlap. Route all bridge calls through one serial actor/queue. Make `stop()` idempotent with a single owner. *(The synthetic/playback/OSC default path is race-free; this bites only with a live Muse.)*

---

## HIGH

### H1 — Core ML softmax has no max-subtraction → NaN on strong gestures
`Sources/BCIClassifier/CoreMLIntentClassifier.swift:153-169`
The model emits raw logits (`train-intent-classifier.py:179` is a bare `nn.Linear` under `CrossEntropyLoss`; the Python server softmaxes as `np.exp(logits - np.max(logits))`). The Swift port does `expf(v)` with no max-subtraction. Any logit ≳ 88 overflows to `+inf` → `sum = inf` → argmax class `inf/inf = NaN` → fails `p > maxValue` → returns the **wrong** class at confidence 0, silently dropped by the smoother. Strong clenches produce the largest logits, so the clearest intents are the ones lost. **Fix:** subtract `max(logits)` before `expf`, matching the reference.

### H2 — No CI exists; the README says there is
No `.github/workflows`, CI YAML, git hooks, or Makefile anywhere (all matches are vendored deps). Yet `README.md:56,188` advertise "CI regression against a golden recording." Actual enforcement is a manual `swift test --filter GoldenRecordingRegressionTests`, which **skips silently** when its fixture is absent (the derived `Tests/BCIEEGTests/Fixtures/reference_pipeline.json` *is* committed, so it *can* run). **Fix:** add a GitHub Actions macOS workflow running `swift build` + `swift test`, and assert the golden fixture is present so the suite can't pass vacuously. Until then, soften the README wording to "regression test (run manually)."

### H3 — Working tree carries ~12 MB of stray, un-ignored artifacts
Not covered by `.gitignore` (confirmed via `git check-ignore`): `default.profraw` (7.8 MB), `phase_b_live_screenshot.png` (3.7 MB), `paper/main.{aux,bbl,blg,out,pdf}`, `.hermes/`, `arxiv_cache/`, `Evaluation/results/**/*.pid`, `Evaluation/results/repro/bin/`, generated `deep-research-report.md` + `NeuralCompose_dream_prompt.md`. **Fix:** add ignore rules (`*.profraw`, `paper/*.{aux,bbl,blg,out,pdf}`, `.hermes/`, `arxiv_cache/`, the PID/bin paths, the root PNG) and delete the binaries. Two untracked files look like *real work* and should be committed instead: `Scripts/convert_muse_validation_recordings.py`, `docs/reviews/phase-3.5-stall-watchdog-review.md`. *(Positive: `.env` and `.DS_Store` are correctly ignored — no secret leak.)*

### H4 — 15 unpushed commits + 8 worktrees are a single-disk reconciliation hazard
The entire dialectic-engine / co-dev-loop line (`origin/feature/spoken-generation-loop..HEAD`) exists only on this disk. 6 worktree branches are local-only and never pushed (`feature/af7-channel-substitution`, `sandbox/ollama-bci-loop`, `claude/keen-hypatia-555552`, `claude/competent-robinson-ddf10c`, `protocols/passive-overnight-bci`, `worktree-stage-3-5-design`). 2 worktrees hold uncommitted changes on stale branches (`competent-robinson-ddf10c` — 7 modified files incl. `Package.swift`/`AppViewModel.swift`, last commit 2026-07-10; `clever-mcclintock-9b112f`, dir name ≠ its checked-out branch), and `interesting-rubin-0ff99e` is a detached HEAD. **Fix:** push/PR the main line now; triage each worktree (commit/stash or discard the two dirty ones), push or delete local-only branches, then `git worktree remove` + `git worktree prune` the finished ones.

### H5 — `AppViewModel` is a god-object (1,383 LOC, ~18 responsibilities)
`Sources/NeuralComposeApp/AppViewModel.swift`: 45 `@Published`, 22 public methods, 12 injected deps, 44 `Task` sites, imports all six BCI modules. It is simultaneously the pipeline supervisor, five device/IO controllers, three experimental-loop managers, the telemetry sink, an env-var config parser, and the command-dispatch target. Notably the ~180-line EEG retry/backoff/fallback FSM (`:434-617`) lives inline in a `Task.detached` closure with local mutable state (untestable). **Fix:** decompose into ~10 small `@MainActor ObservableObject`/`actor` controllers built by the composition root and injected — `EEGPipelineController`, `EEGStreamSupervisor` (actor), `AdaptiveGenerationController`, `CalibrationController`, `ImaginedSpeechController`, `VoiceIOController`, `VoiceCommandController`, `RefinementController`, `SpokenGenerationLoopController`, `HypnagogicLoopController`, `TelemetryCoordinator` — leaving `AppViewModel` a thin coordinator. This also fixes the 18-parameter `PrivacyIndicatorView` for free.

### H6 — The sole network-egress module is the least-tested critical module
`Sources/BCICloudBridge/ClaudeCLIGenerator.swift` (161 LOC) is the one deliberate runtime exception to "no network," yet `Tests/BCICloudBridgeTests/ClaudeCLIGeneratorTests.swift` (45 LOC) covers only JSON-envelope parsing; the actual egress path (`claude -p`, `Process` construction, what text leaves the device) is "manual smoke only." For a privacy-first BCI the egress boundary itself is unverified. **Fix:** add an integration test pointing `executableURL` at a stub script, asserting exactly what is sent off-device and that the constrained system prompt is applied. *(Related: the real ANE `CoreMLIntentClassifier` also has no tests — the golden regression runs against the mock — so production inference, incl. H1, is uncovered.)*

### H7 — UI frameworks imported into the headless streaming library (layer violation)
`Sources/BCIEEG/NeuralWorkspaceView.swift` (753 LOC) and `EEGScalpPlotterView.swift` (308) import AppKit/SceneKit/QuartzCore *inside* `BCIEEG`. Anything linking the streaming library — including `BCIEEGTests` — now pulls UI frameworks, and a headless/CLI stream consumer can't avoid SceneKit. This is the one real structural layer violation. **Fix:** move these views to `NeuralComposeApp` or a dedicated `BCIVisualization` target.

### H8 — Track B never records the `rest` class
`Sources/BCIEEG/Calibration/TrackBRecorder.swift:148-151, 174-211` — `markPhase` opens a capture window only on `.active`; `.rest`/`.idle` open nothing and `recordSample` drops all samples while no window is open. So `imagined_eeg.csv` holds only active-phase rows, even though `ImaginedWordClass.wordRest = 0` is a defined, documented class. A 3-class (rest/yes/no) decoder has zero rest examples and can't re-derive them. **Fix:** open a `.wordRest`-labeled window on `.rest` entry, mirroring the `.active` branch. *(Research arm — experimental, but this silently invalidates the data collection it exists to do.)*

### H9 — Unsynchronized cross-actor mutation of stream config
`Sources/BCIEEG/BrainFlowService.swift:82-83`, `Sources/BCIEEG/PlaybackEEGStream.swift:137,178,187` — `effectiveSampleRate`/`channelCount` are `public private(set) var` on `@unchecked Sendable` classes, written off-main in `start()` without the lock while read on the main actor (`AppViewModel.swift:909,971`, windowing-config construction). Torn read/write across concurrency domains the compiler can't see. **Fix:** guard behind the existing `lock`, or make them immutable after first resolve, or capture once and pass as a `let`.

---

## MEDIUM (selected — full list in the per-lens notes)

- **M1 — Dwell-select auto-commits on ambient rest.** `Sources/BCICore/Intent/IntentSmoother.swift:109-117`: dwell keys on `.rest` (the idle class); ~4 s of stillness fires `.selectActive`, and after the 6-window refractory it re-fires, producing a runaway ~1 word/10 s of unintended commits when the user just stops. **Fix:** require a non-rest `.advance` between successive dwell-selects, or raise `dwellActivationCount`/refractory against measured false-commit rates.
- **M2 — Composition `catch` isn't cancellation-guarded.** `Sources/BCICore/Composition/TextCompositionController.swift:230-238`: the success path guards `id == currentCancellation` (`:220`) but the `catch` doesn't, so a superseded request that throws still flips the FSM to `showingCandidates`/`isPredicting=false`, clobbering the newer in-flight request (stale commit possible). **Fix:** add the same guard at the top of `catch`.
- **M3 — Egress subprocess can deadlock / hang.** `ClaudeCLIGenerator.swift:109-123` drains stdout via `readDataToEndOfFile()` *inside* `terminationHandler`, so output > ~64 KB pipe buffer blocks the child forever; and there is no internal timeout (`:99-135`) — it relies entirely on caller cancellation, unlike `SubprocessProbe.run` which races a timeout. **Fix:** drain concurrently (readability handler / reader task) and add a bounded timeout.
- **M4 — OSC UDP listener binds `0.0.0.0` with no auth.** `Sources/BCIEEG/OSC/MindMonitorOSCStream.swift:87,97-99` — inbound port 5000 on all interfaces for the `remotePhone` mode; trust is fully delegated to a private VPN (Tailscale). Malformed packets are dropped safely, but any reachable host can inject "EEG" samples. **Fix:** bind to the VPN interface / firewall the port, or add a shared-secret check.
- **M5 — No lint/format config** for ~20 K LOC of Swift 6. Add `.swift-format` (already transitive via mlx-swift-examples) and gate it in CI.
- **M6 — Duplicate ADR number.** Two `ADR-004` files in `docs/architecture/decision-log/` (both "Accepted"); `CONTRIBUTING.md` treats this log as canonical. Renumber the later (embedding-contract) one to ADR-009+.
- **M7 — Base-layer test targets depend on downstream `BCIClassifier`.** `Package.swift`: `BCICoreTests`/`BCIEEGTests` link a CoreML-bound module, inverting layer direction (BCICore's "pure" tests can't run without CoreML). **Fix:** a dedicated `PipelineIntegrationTests` target for the golden/BGE-replay suites.
- **M8 — Dead compute-mode Picker.** `ContentView.swift:288` binds `$viewModel.computeMode`, but nothing reconfigures the classifier on change (resolved once, immutable) — a silent no-op control. Wire a reconcile path or remove it.
- **M9 — Sleep-viz theta uses corrupted IIR state.** `NeuralWorkspaceView.swift:579-587` re-runs the whole ring buffer through a *persisted* biquad each frame; the theta RMS driving node elevation is not a valid band-power estimate. Reset `z1/z2` per frame or filter only new samples. *(Viz-only.)*
- **M10 — JEPA anti-collapse pressure on the wrong tensor.** `WorldModel/loss.py:106-113`: VICReg var/cov act on `z_pred` while the online encoder embedding is never directly regularized; a collapsed encoder still satisfies the variance hinge via the action. `train.py:252` detects but doesn't prevent it. Add explicit var+cov on the encoder output. *(Research spike.)*
- **M11 — No timeout on the predictor call.** `TextCompositionController.swift:213-218`: if MLX wedges, the controller stays `.predicting` forever with no recovery (EEG dropped while predicting → no newer request can cancel it). Add a timeout racer.
- **M12 — Config scattered across 7 sites.** `ProcessInfo.environment` read in BrainFlowService, ClassifierFactory, PredictorFactory, SpectralStateEstimatorFactory, WorldModelDemoFactory, AppContainer, **and AppViewModel**. Centralize in one `AppEnvironmentConfig` resolved in `makeDefault`. Also: `pipelineMode` is built two ways that must be hand-synced (`AppContainer.swift:59-68` vs `AppViewModel.swift:1282-1296`) — extract one builder.

---

## LOW (notable)

- **L1 — Argument-injection surface (no shell injection).** `ClaudeCLIGenerator.swift:88-94` passes args via array (execve, no shell), but the user-derived `prompt` is the trailing positional with no `--` end-of-options guard; a transcript starting with `-`/`--` could be read as a flag. Insert a literal `"--"` before the prompt or pass via stdin.
- **L2 — `SpectralArtifactGate.isClean` passes NaN.** `Sources/BCICore/Preprocessing/SpectralArtifactGate.swift:24`: `abs(value) > threshold` is false for NaN, so a NaN sample is judged "clean" and propagates downstream (defused today only by coincidental NaN-filtering). Use `!value.isFinite || abs(value) > threshold`.
- **L3 — `BandpassFilter` is dead and mis-centered.** `Sources/BCICore/Preprocessing/BandpassFilter.swift:75` — never applied; docstring wrongly claims it constrains to the classifier's training band (classifier trains on unfiltered data); `designBiquad` uses the *arithmetic* mean of edge frequencies (centers 1–30 Hz at 15.5 Hz instead of geometric ~5.5 Hz). Delete it, or center on the geometric mean and actually apply it in both training and inference.
- **L4 — Latent HF-Hub networking in deps.** `swift-transformers`/MLX can fetch from `huggingface.co`, but every model config is `ModelConfiguration(directory:)` from a local URL with a `fileExists` guard — the network path is never reached. Add an architecture test asserting configs are always `.directory` so a future `(id:)` can't silently open egress.
- **L5 — Missing `.env.example`.** `.gitignore` whitelists `!.env.example` but no such file exists; contributors get no variable template (`HF_API_TOKEN`, optional `ANTHROPIC_API_KEY`). Add one with placeholder values.
- **L6 — Stale "delete once diagnosed" comment.** `Package.swift` — `MLXProbe`/`SpectralProbe` are **live runtime subprocess deps** (`PredictorFactory.swift:120`, `SpectralStateEstimatorFactory.swift:88`), not dead code; the MLXProbe "delete" note is stale and deleting the target would break `PredictorFactory`. Correct the comment.
- **L7 — No App Sandbox / entitlements.** The no-network invariant is enforced by convention only. A sandboxed distribution target that omits `network.client`/`network.server` entitlements would make the OS hard-block accidental egress (belt-and-suspenders; the `claude` CLI runs as a separate process and networks regardless — the intended exception).
- **L8 — Dead helpers + duplication.** `NeuralWorkspaceView.swift:655 (edgePulseForFSM)`, `:692 (bandRMS, self-labeled legacy)` have no callers. `throwingStream` duplicated verbatim (`NeuralWorkspaceHost.swift:157`, `SleepValidationView.swift:325`); `documentDirectory`→`"NeuralCompose"` path built 4× — extract `AppPaths`.
- **L9 — Track B phase-entry detection is a fragile exact-match** on a droppable `.bufferingNewest(64)` stream (`TrackBRecorder.swift:168,176`): a >6.4 s consumer stall drops the sole `.active`-entry event and the trial silently never opens. Make it edge-triggered on phase change.

---

## What's strong (keep it)

- **The no-network invariant holds.** A full `Sources/` sweep finds exactly two network-touching modules: the deliberate, opt-in, well-gated `ClaudeCLIGenerator` egress (text-only — no EEG/audio leaves the device; no API key on disk; lazily constructed only after mic/speech auth) and the inbound OSC listener. No `URLSession`/`URLRequest`/`CFNetwork`/raw sockets anywhere.
- **Concurrency architecture is deliberate and mostly correct:** real `actor`s for the FSM/composition/MLX runtime, `OSAllocatedUnfairLock` in `MetricsCollector`, race-free `AsyncMulticastChannel` fan-out, UUID-token actor-reentrancy handling, and a genuinely enforced single-MLX-runtime boundary (no source outside `BCILLM` imports MLX).
- **The live intent→text path is fundamentally sound:** correct 50%-overlap windowing, safe ring-buffer wraparound, wrapping UInt64 counters, no train/inference normalization mismatch, non-silent classifier/predictor fallbacks (they `warning`-log), and MLX's own softmax *does* subtract the max.
- **Architecture:** `BCICore` imports only Foundation; the three domain protocols are minimal, `Sendable`, frozen; `AppContainer` is a genuine composition root with stub-by-default injection and no app-level singletons.
- **Rigor:** deterministic golden-recording + semantic-replay regression, 9 ADRs, confidence-rated claims (Established/Plausible/Unproven), a pre-registered hypothesis registry, honest "hardware-limited" upper bounds, and near-zero TODOs / `fatalError`.

---

## Suggested order of attack

1. **C1** — fix the BrainFlow use-after-free (structured teardown). Ship before any more live-hardware runs.
2. **H4** — push the 15 commits + triage the 8 worktrees. Your work is single-copy right now.
3. **H1** — one-line softmax max-subtraction (silent-wrong-class bug on the core path).
4. **H2 + H3 + M5** — add a CI workflow (`swift build`/`test` + fixture assertion + `.swift-format`), gitignore + delete the 12 MB of artifacts, commit the two real untracked files.
5. **H6** — an egress integration test (the privacy boundary should be the *best*-tested module, not the worst).
6. **H5** — begin the `AppViewModel` decomposition (start by extracting `EEGStreamSupervisor` from the inline `:434-617` FSM).
7. **H7** — move the SceneKit/AppKit views out of `BCIEEG`.
8. **M1, M2, M11** — the live-path UX/robustness trio (dwell auto-commit, catch guard, predictor timeout).
9. **H8** — Track B rest-class recording, before collecting more imagined-speech data.
10. Sweep the Low/hygiene items (ADR-004 renumber, stale comments, dead code, `.env.example`).

*Full per-lens findings (privacy, concurrency, architecture, hygiene, correctness) are available on request — this report consolidates and de-duplicates them.*
