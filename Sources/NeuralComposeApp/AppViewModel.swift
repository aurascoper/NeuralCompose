import Foundation
import SwiftUI
import Combine
import BCICore
import BCIEEG
import BCIClassifier
import BCILLM
import BCIVoice
import BCICloudBridge

public struct CalibrationMetrics: Sendable {
    public let channelCount: Int
    public let channelLabels: [String]
    public let rms: [Float]
    public let peak: [Float]
    public let samplesPerSec: Double
}

/// Coarse signal-health bucket derived from per-channel RMS each window.
/// "Healthy" range is 5–200 µV — below = electrode lifted / dry, above =
/// muscle/motion contamination or 50/60 Hz interference.
public enum SignalQuality: Sendable, Equatable {
    case healthy   // ≥3/4 channels in range
    case poor      // 1–2 channels in range
    case lost      // 0 channels in range
}

/// Owns the live pipeline lifecycle. The view model itself stays on
/// `@MainActor` so SwiftUI observation is straightforward, but the heavy
/// loops — EEG ingestion, windowing, classification, smoothing — all run on
/// **detached** tasks so they never block the UI executor.
///
/// Restart-safe: every `start()` call recreates the `BoundedAsyncChannel<EEGWindow>`
/// and the `TextCompositionController`. `stop()` finishes the channels (so
/// any in-flight iterators terminate) and a subsequent `start()` will set up
/// fresh ones.
///
/// Runtime supervisor: if the live EEG stream throws or completes
/// unexpectedly and we are not already running synthetic, the streamTask
/// swaps in `EEGStreamFactory.makeSynthetic()` and continues, updating
/// `pipelineMode` so the privacy banner reflects the degraded state.
/// The single hypnagogic interaction mode — one axis, replacing the old
/// `InteractionStyle × ContextProfile` split. `mirror` is the plain reply
/// (`HypnagogicDialogueLoop`, ONE cloud call/turn); `focused` / `reflective` /
/// `contemplative` run the dialectic competition (`HypnagogicDialecticLoop`,
/// persistent tension, non-deterministic resolution, TWO cloud calls/turn) at
/// the matching `ContextProfile` tuning. "Dialectical" is no longer a separate
/// toggle: choosing `reflective` — the canonical dialectical behaviour — *is*
/// choosing dialectical.
public enum HypnagogicMode: String, CaseIterable, Sendable, Identifiable {
    case mirror, focused, reflective, contemplative
    public var id: String { rawValue }

    /// The dialectic tuning profile for this mode, or nil for `mirror` (the
    /// non-competing reply loop). The non-mirror rawValues line up with
    /// `ContextProfile`, so this is a direct lift.
    public var profile: ContextProfile? { ContextProfile(rawValue: rawValue) }

    /// Whether this mode runs the dialectic loop (two cloud calls/turn).
    public var isDialectical: Bool { profile != nil }

    public var label: String {
        switch self {
        case .mirror:        return "Mirror"
        case .focused:       return "Focused"
        case .reflective:    return "Reflective"
        case .contemplative: return "Contemplative"
        }
    }
}

@MainActor
public final class AppViewModel: ObservableObject, AppCommandDispatchTarget {

    // ── Published state ──────────────────────────────────────────────────
    @Published public private(set) var composedText: String = ""
    @Published public private(set) var candidates: [PredictedWord] = []
    @Published public private(set) var highlightIndex: Int = 0
    @Published public private(set) var isPredicting: Bool = false
    @Published public private(set) var lastCommittedWord: String?
    /// Mirrors `TextCompositionController.Snapshot.commitSequence` — the
    /// actual signal `telemetryEvent` compares, since `lastCommittedWord`
    /// alone can't tell "no new commit" apart from "the user genuinely
    /// committed the same word twice in a row."
    private var lastCommitSequence: UInt64 = 0
    @Published public private(set) var pipelineMode: PipelineMode
    /// Reserved for genuine *live* pipeline failures (EEG stream drops,
    /// calibration/Track-B start failures, etc.) — never populated from
    /// one-time startup substitution notices. See `startupWarning` for
    /// those. `PrivacyIndicatorView` keys its red "hard error" severity off
    /// this field specifically, so it must stay narrow.
    @Published public private(set) var lastError: String?
    /// One-time notice from container resolution when the classifier or
    /// predictor fell back to a stand-in at startup (e.g. MLX weights
    /// present but unusable in this build, so the stub predictor is in
    /// use). Kept separate from `lastError` for the same
    /// separation-of-concerns reason `voiceWarning`/`commandWarning`/
    /// `refinementWarning` are each their own field: a correctly-handled
    /// stand-in is not a live pipeline health signal, and conflating the
    /// two made `PrivacyIndicatorView` show a red "Degraded" banner for a
    /// case its own doc comment defines as the amber "stand-in" tier.
    @Published public private(set) var startupWarning: String?
    @Published public private(set) var metricsSnapshot: MetricsCollector.Snapshot
    @Published public var computeMode: ClassifierComputeMode
    @Published public private(set) var isRunning: Bool = false

    @Published public private(set) var isCalibrating: Bool = false
    @Published public private(set) var calibrationWindowCount: Int = 0
    @Published public private(set) var calibrationSampleRate: Double = 0
    @Published public private(set) var droppedWindowCount: Int = 0
    @Published public private(set) var calibrationMetrics: CalibrationMetrics?

    @Published public private(set) var signalQuality: SignalQuality?
    @Published public private(set) var isReconnecting: Bool = false

    /// Off by default ("shadow mode"): `detectedAdaptation` is always kept
    /// current from live `signalQuality` so the badge is informative from
    /// launch, but it only reaches the predictor (`appliedAdaptation`) once
    /// the user explicitly opts in here — lets the detection be judged
    /// against lived experience before it's trusted to change output.
    @Published public var adaptiveComplexityEnabled: Bool = false {
        didSet { applyAdaptiveGeneration() }
    }
    /// What the current `signalQuality` maps to via `SignalQualityGenerationRules`,
    /// regardless of whether adaptive mode is enabled.
    @Published public private(set) var detectedAdaptation: GenerationAdaptation = .raw
    /// What's actually been pushed to the composition controller — equals
    /// `.raw` whenever `adaptiveComplexityEnabled` is false.
    @Published public private(set) var appliedAdaptation: GenerationAdaptation = .raw
    /// Milestone B state source — always kept current regardless of the
    /// toggle, same shadow-mode invariant as `detectedAdaptation`. `nil`
    /// means the estimator has no opinion (stub, missing weights, wrong
    /// shape, artifact-contaminated window, or untrusted anchor space) —
    /// `applyAdaptiveGeneration()` falls back to `signalQuality` in that case.
    @Published public private(set) var detectedSpectralState: SpectralState?

    /// The latest app-watchdog health snapshot (nil until the pipeline starts).
    /// Drives the degraded banner; the same snapshot is written each tick to
    /// `~/Documents/NeuralCompose/health.json`.
    @Published public private(set) var healthSnapshot: HealthSnapshot?

    /// Off by default, mirroring `adaptiveComplexityEnabled`'s opt-in shape:
    /// no interaction is logged locally until the user explicitly turns
    /// this on (see `docs/architecture/decision-log/ADR-005-local-interaction-logging.md`).
    @Published public var interactionLoggingEnabled: Bool = false

    /// Separate, explicit opt-in for the local JEPA training data set. While
    /// on, the pipeline retains a bounded in-memory feature window and writes
    /// one paired transition per genuine word commit. It is intentionally not
    /// coupled to the narrower interaction-log toggle.
    ///
    /// Clears the underlying ring buffer on every transition (both
    /// enabling and disabling) — `JEPASpectralStateRingBuffer`'s `isFull`
    /// used to be a one-way latch that never reset, so toggling this off
    /// and back on could return stale pre-toggle-off data as if it were a
    /// freshly-completed window, splicing unrelated chronological data
    /// into one persisted transition.
    @Published public var jepaTransitionCaptureEnabled: Bool = false {
        didSet {
            guard oldValue != jepaTransitionCaptureEnabled else { return }
            jepaTransitionCapture.clear()
        }
    }

    /// Separate, explicit opt-in for the synthetic-task JEPA+MPC planning
    /// demo (see `WorldModel/README.md`, `Sources/WorldModelDemo/`). Unlike
    /// `jepaTransitionCaptureEnabled`, this gates no data collection at
    /// all — it only controls whether the self-contained synthetic-task
    /// demo window actually runs its closed-loop simulation and calls the
    /// real on-device predictor for its illustrative panel (see
    /// `WorldModelMPCDemoView`). Off by default; unrelated to
    /// `interactionLoggingEnabled` and `jepaTransitionCaptureEnabled`,
    /// which this never reads or modifies.
    @Published public var worldModelDemoEnabled: Bool = false

    /// Experimental, opt-in spoken-generation loop (see `SpokenGenerationLoop`,
    /// `SpokenGenerationHonesty`). Off by default and session-scoped like every
    /// other opt-in here. Owns a running `Task`, so — unlike the view-lifecycle
    /// `worldModelDemoEnabled` — it needs a `didSet` to start/stop that loop.
    @Published public var spokenGenerationLoopEnabled: Bool = false {
        didSet {
            guard oldValue != spokenGenerationLoopEnabled else { return }
            reconcileSpokenGenerationLoop()
        }
    }

    /// Experimental, opt-in **hypnagogic dialogue loop** (see
    /// `HypnagogicDialogueLoop`). Off by default and session-scoped. UNLIKE every
    /// other opt-in here, when enabled it (a) captures microphone audio during
    /// listen turns and (b) may send transcript *text* to a cloud LLM via the
    /// `claude` CLI — the sole deliberate exception to "No network at runtime"
    /// (decision_registry entry 8). Audio stays on-device (on-device STT); only
    /// text can leave; nothing is persisted. Manual trigger only — NOT wired to
    /// any sleep-stage detector. The privacy banner must reflect this while active.
    @Published public var hypnagogicLoopEnabled: Bool = false {
        didSet {
            guard oldValue != hypnagogicLoopEnabled else { return }
            reconcileHypnagogicLoop()
        }
    }

    /// The hypnagogic interaction mode when the loop is enabled: `mirror` (plain
    /// reply, one cloud call/turn) or `focused` / `reflective` / `contemplative`
    /// (the dialectic loop at that tuning, two cloud calls/turn). Changing it
    /// while active rebuilds the loop. Defaults to the plain mirror — the
    /// lower-egress option.
    @Published public var hypnagogicMode: HypnagogicMode = .mirror {
        didSet {
            guard oldValue != hypnagogicMode, hypnagogicLoopEnabled else { return }
            reconcileHypnagogicLoop()
        }
    }

    // ── Track B (imagined speech) — additive, never touches Track A state ─
    @Published public private(set) var isImaginedSpeechRecording: Bool = false
    @Published public private(set) var imaginedSpeechState: ImaginedSpeechProtocolState = .init(
        phase: .idle, target: nil, trialIndex: 0, totalTrials: 0,
        phaseStartTimestamp: 0, phaseDuration: 0, timeRemaining: 0
    )
    @Published public private(set) var imaginedActiveSampleCount: Int = 0
    @Published public private(set) var imaginedDroppedSampleCount: Int = 0
    @Published public private(set) var imaginedSessionURL: URL?

    // ── Voice I/O — push-to-talk dictation + explicit-trigger TTS. Event-
    //    driven only: `isDictating` is true only while the mic button is
    //    held, never as a background/continuous state. `voiceWarning` is
    //    kept separate from `lastError`, which stays reserved for EEG/
    //    classifier/predictor pipeline health — voice degradation is an
    //    on-demand concern, not a pipeline health signal. ─────────────────
    @Published public private(set) var isDictating: Bool = false
    @Published public private(set) var isSpeaking: Bool = false
    @Published public private(set) var voiceWarning: String?

    // ── Voice command listening — push-to-talk ASR → AppCommand. Same
    //    privacy posture as dictation: mic open only between explicit
    //    start/stop pairs, never a continuous stream. `isCommanding` is
    //    the banner flag; `commandWarning` is its own field (mirrors
    //    `voiceWarning` / `refinementWarning` separation-of-concerns
    //    pattern) so a command failure doesn't pollute the dictation
    //    health signal. ───────────────────────────────────────────────
    @Published public private(set) var isCommanding: Bool = false
    @Published public private(set) var commandWarning: String?

    // ── Semantic dialectic engine — explicit-trigger thesis/antithesis/
    //    synthesis refinement of the composed sentence. Never runs
    //    automatically (see `DialecticEngine`'s doc comment for why: three
    //    sequential LLM decode passes are too slow for the carousel's hot
    //    path). `refinementWarning` is its own field for the same
    //    separation-of-concerns reason `voiceWarning` is separate from
    //    `lastError`. ─────────────────────────────────────────────────────
    @Published public private(set) var isRefining: Bool = false
    @Published public private(set) var refinementSuggestion: Refinement?
    @Published public private(set) var refinementWarning: String?

    // ── Command dispatch bridge ───────────────────────────────────────────
    //    Transient, view-side navigation requests published by the
    //    `AppCommandDispatcher` and consumed by SwiftUI's `.onChange`.
    //    The dispatcher is `@MainActor` but not a SwiftUI view, so it
    //    cannot call `openWindow(id:)` directly; it sets these fields
    //    and the view's `.onChange` performs the SwiftUI action, then
    //    immediately clears the field so subsequent emissions re-fire.
    //    See `AppCommandDispatcher`'s doc comment for the full rationale.
    @Published public var pendingWindowOpen: String?
    @Published public var pendingTab: PendingTab?

    // ── Immutable wiring (lives for the lifetime of the view model) ──────
    public let container: AppContainer
    private let metrics: MetricsCollector
    private let windowing: EEGWindowing
    private let smoother: IntentSmoother
    private let classifier: any IntentClassifying
    private let predictor: any NextWordPredicting
    private let spectralEstimator: any SpectralStateEstimating
    private let interactionLogger: any InteractionLogging
    private let jepaTransitionCapture: any JEPATransitionCapturing
    private let voiceOutput: any SpeechSynthesizing
    private let voiceInput: any DictationRecognizing
    private let voiceCommandInput: any VoiceCommandRecognizing
    /// Set by `AppLoader` after the dispatcher is constructed. Used
    /// by `stopCommandListening()` to dispatch the recognized
    /// command through the same path the palette / menu / buttons
    /// use (rather than calling `AppViewModel` methods directly).
    /// `weak` so the dispatcher's lifetime is owned by the loader,
    /// not extended by the view model.
    public weak var commandDispatcher: AppCommandDispatcher?
    private let dialecticEngine: DialecticEngine
    /// Experimental spoken-generation loop, built lazily on first enable so its
    /// adaptation closure can capture a fully-initialized `self`. Nil while off.
    private var spokenLoop: SpokenGenerationLoop?
    /// Serializes start/stop of `spokenLoop` so a fast toggle on→off can never
    /// leave a started loop with no handle to stop it — each reconcile awaits the
    /// previous one, then applies the latest toggle value.
    private var spokenLoopReconcile: Task<Void, Never>?
    /// Experimental hypnagogic loop + its serializing reconcile task, mirroring
    /// the spoken-loop pattern. Nil while off. Its mic listener and cloud
    /// generator are built lazily in `ensureHypnagogicLoopRunning` and kept OUT
    /// of the default AppContainer graph, so the network-egress path is
    /// instantiated only while the loop is enabled.
    private var hypnagogicLoop: (any HypnagogicRunnable)?
    /// The mode of the currently-built loop, so a change rebuilds it.
    private var hypnagogicLoopBuilt: HypnagogicMode?
    private var hypnagogicLoopReconcile: Task<Void, Never>?
    /// Stable relay of the dialectic loop's spoken-node events (Stage 1d). The
    /// 3D workspace subscribes here once at bind time, decoupled from loop
    /// lifetime: each dialectic loop's `spokenNodeStream()` is forwarded into
    /// this channel, so the subscription survives mode changes and rebuilds.
    /// On-device only — nothing here leaves the machine.
    private let spokenNodeRelay = AsyncMulticastChannel<SpokenNodeEvent>(capacity: 32)
    private var spokenNodeForwardTask: Task<Void, Never>?

    // ── Per-start resources (recreated each call to start()) ─────────────
    private var composition: TextCompositionController?
    private var windowChannel: BoundedAsyncChannel<EEGWindow>?
    /// Internal broadcast fan-out for raw `EEGSample`s. Created in `start()`,
    /// finished in `stop()`. Every visualization consumer gets its own stream
    /// via `subscribe()`, so the plotter and the channel-health provider each
    /// receive the full sample stream rather than racing for a split of it.
    /// See the doc comment on `liveSampleStream()` for the single-owner
    /// invariant this field enforces.
    private var sampleChannel: AsyncMulticastChannel<EEGSample>?
    /// Broadcast fan-out of raw classifier output, independent of the
    /// FSM/carousel path. Diagnostic consumers (e.g. the 3D workspace
    /// visualizer) subscribe here instead of threading through
    /// `IntentSmoother`/`TextCompositionController`, so a debug view never
    /// becomes coupled to composition internals. See `liveClassifierStream()`.
    private var classifierChannel: AsyncMulticastChannel<IntentPrediction>?
    private var calibrationRecorder: CalibrationRecorder?
    private var trackBRecorder: TrackBRecorder?
    private var imaginedProtocol: ImaginedSpeechProtocol?
    private var imaginedProtocolTask: Task<Void, Never>?
    private var imaginedStatsTask: Task<Void, Never>?

    private var streamTask: Task<Void, Never>?
    private var classifyTask: Task<Void, Never>?
    private var snapshotTask: Task<Void, Never>?
    private var carouselTask: Task<Void, Never>?
    private var metricsTask: Task<Void, Never>?
    private var healthTask: Task<Void, Never>?
    /// Always-on watchdog file writer (health.json + health-<day>.jsonl). Not
    /// gated by any opt-in — it records diagnostic metadata only, no transcripts.
    private let healthLogger = HealthLogger()

    public init(container: AppContainer) {
        self.container = container
        self.metrics = container.metrics
        self.classifier = container.classifierResolved.classifier
        self.predictor = container.predictorResolved.predictor
        self.spectralEstimator = container.spectralEstimatorResolved.estimator
        self.interactionLogger = container.interactionLogger
        self.jepaTransitionCapture = container.jepaTransitionCapture
        self.voiceOutput = container.voiceOutputResolved.synthesizer
        self.voiceInput = container.voiceInputResolved.recognizer
        // The voice command recognizer holds a parser closure that
        // wraps whatever recognizer the app is currently using
        // (FuzzyCommandRecognizer today). Captured here so the
        // voice service's actor never has to know about the
        // recognizer type.
        self.voiceCommandInput = container.voiceCommandResolved.recognizer
        self.dialecticEngine = DialecticEngine(
            generator: container.predictorResolved.generator,
            metrics: container.metrics
        )
        self.pipelineMode = container.pipelineMode
        self.computeMode = container.classifierResolved.computeMode
        self.windowing = EEGWindowing(config: container.windowingConfig)
        self.smoother = IntentSmoother(config: container.smootherConfig)
        self.metricsSnapshot = container.metrics.snapshot()
        if let w = container.classifierResolved.warning {
            self.startupWarning = w
        } else if let w = container.predictorResolved.warning {
            self.startupWarning = w
        } else if let w = container.spectralEstimatorResolved.warning {
            // Previously dropped entirely — a real probe crash/timeout/init
            // failure here silently fell back to the stub estimator with
            // zero UI indication, unlike every sibling subsystem's
            // equivalent failure path.
            self.startupWarning = w
        }
        if let w = container.voiceOutputResolved.warning {
            self.voiceWarning = w
        } else if let w = container.voiceInputResolved.warning {
            self.voiceWarning = w
        }
        if let w = container.voiceCommandResolved.warning {
            self.commandWarning = w
        }
    }

    // MARK: - Lifecycle

    public func start() async {
        guard !isRunning else { return }
        isRunning = true
        await windowing.reset()
        await smoother.reset()

        // Per-start resources.
        let channel = BoundedAsyncChannel<EEGWindow>(capacity: 8, overflow: .dropOldest)
        // Internal broadcast fan-out of raw samples. Capacity 8 with
        // dropOldest keeps a recent history available per subscriber; each
        // visualization consumer gets its own stream via `subscribe()`. The
        // production classifier reads from `channel` (windows), not from here.
        let samples = AsyncMulticastChannel<EEGSample>(capacity: 8, overflow: .dropOldest)
        // Same pattern as `samples`: a broadcast fan-out separate from the
        // channel that actually drives composition, so diagnostic consumers
        // never depend on FSM/carousel internals.
        let classifications = AsyncMulticastChannel<IntentPrediction>(capacity: 8, overflow: .dropOldest)
        let composition = TextCompositionController(predictor: predictor, metrics: metrics)
        self.windowChannel = channel
        self.sampleChannel = samples
        self.classifierChannel = classifications
        self.composition = composition
        await composition.start()
        applyAdaptiveGeneration()
        // Opt-in, default no-op: honour NEURALCOMPOSE_HYPNAGOGIC_AUTOSTART so a
        // scripted live run can start the loop without the UI toggle (all auth +
        // egress-disclosure gates preserved). Fires once — start() is guarded.
        applyHypnagogicAutostartFromEnvironment()

        // ── snapshots → UI (MainActor) ────────────────────────────────────
        snapshotTask = Task {
            for await snap in composition.snapshots {
                await MainActor.run { [weak self] in
                    self?.apply(snapshot: snap)
                }
            }
        }

        // ── 1.5 s carousel tick (off-main) ────────────────────────────────
        carouselTask = Task.detached(priority: .userInitiated) { [composition] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                if Task.isCancelled { break }
                await composition.tick()
            }
        }

        // ── metrics polling — 4 Hz (off-main, then hop for UI write) ──────
        let metricsRef = self.metrics
        metricsTask = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000)
                if Task.isCancelled { break }
                let snap = metricsRef.snapshot()
                await MainActor.run { self?.metricsSnapshot = snap }
            }
        }

        // ── health watchdog — 0.5 Hz (off-main): assemble a HealthSnapshot from
        //    the resolved backend kinds + pipeline state + EEG throughput, write
        //    it to health.json, and publish it for the degraded banner. Always
        //    on; observes only, never changes runtime behaviour.
        let healthLoggerRef = healthLogger
        let healthStartedAt = Date()
        let wantedProfile = (ProcessInfo.processInfo.environment["NEURALCOMPOSE_BOARD_PROFILE"] ?? "synthetic").lowercased()
        let expectedLive = wantedProfile.contains("muse") || wantedProfile.contains("athena")
        var lastWindowCount = metricsRef.snapshot().windowing.count
        var lastWindowAt = healthStartedAt
        healthTask = Task.detached(priority: .utility) { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if Task.isCancelled { break }
                let nowWindows = metricsRef.snapshot().windowing.count
                let now = Date()
                let dt = max(0.001, now.timeIntervalSince(lastWindowAt))
                let wps = Double(nowWindows &- lastWindowCount) / dt
                lastWindowCount = nowWindows
                lastWindowAt = now
                guard let snap = await self?.assembleHealthSnapshot(
                    now: now, uptime: now.timeIntervalSince(healthStartedAt),
                    windowsPerSecond: wps, expectedLive: expectedLive) else { continue }
                await healthLoggerRef.write(snap)
                await MainActor.run { self?.healthSnapshot = snap }
            }
        }

        // ── EEG supervisor (off-main): start the configured stream; if it
        //    errors or completes and we aren't already on synthetic, fall
        //    back and keep going. Updates `pipelineMode` on the way.
        let initialResolved = container.streamResolved
        let containerRef = container
        let spectralEstimatorRef = self.spectralEstimator
        let jepaTransitionCaptureRef = self.jepaTransitionCapture
        streamTask = Task.detached(priority: .userInitiated) {
            [weak self, windowing, metrics = metricsRef, channel, samples, spectralEstimatorRef, jepaTransitionCaptureRef] in
            var current = initialResolved
            var calibrationSampleCounter = 0
            var calibrationLastLogTime = Date()
            var liveRetries = 0
            let maxLiveRetries = 3
            var samplesThisAttempt = 0
            while !Task.isCancelled {
                await Self.publishMode(current: current, container: containerRef, on: self)
                samplesThisAttempt = 0
                do {
                    let stream = try await current.stream.start()
                    for try await sample in stream {
                        if Task.isCancelled { break }
                        samplesThisAttempt += 1
                        // Single-owner fan-out (see liveSampleStream()).
                        samples.send(sample)

                        // Record sample if in calibration mode (Track A) or
                        // in imagined-speech recording (Track B). The two
                        // recorders are independent sinks — both, neither, or
                        // either can be active. Track A's path is byte-
                        // identical to before; Track B is an additive fork.
                        let (isCalibrating, recorder, trackB) = await MainActor.run {
                            (self?.isCalibrating ?? false,
                             self?.calibrationRecorder,
                             self?.trackBRecorder)
                        }
                        // The first sample of an attempt that follows a
                        // prior failure (liveRetries > 0) is the
                        // "reconnected" moment — the live link is
                        // producing samples again. Logged before
                        // liveRetries gets reset below (samplesThisAttempt
                        // >= 256 branch) so this only fires once per
                        // recovery, right when it actually happens.
                        if samplesThisAttempt == 1, liveRetries > 0, isCalibrating, let recorder = recorder {
                            await recorder.recordTransportEvent(
                                .reconnected, at: Date().timeIntervalSince1970,
                                detail: "after \(liveRetries) retr\(liveRetries == 1 ? "y" : "ies")"
                            )
                        }
                        if isCalibrating, let recorder = recorder {
                            await recorder.recordSample(sample)
                            calibrationSampleCounter += 1
                            let now = Date()
                            if now.timeIntervalSince(calibrationLastLogTime) >= 1.0 {
                                await MainActor.run {
                                    self?.calibrationSampleRate = Double(calibrationSampleCounter) / now.timeIntervalSince(calibrationLastLogTime)
                                }
                                calibrationSampleCounter = 0
                                calibrationLastLogTime = now
                            }
                        }
                        if let trackB = trackB {
                            await trackB.recordSample(sample)
                        }

                        let started = DispatchTime.now()
                        do {
                            if let window = try await windowing.ingest(sample) {
                                metrics.recordWindowing(durationMicros: elapsedMicros(since: started))

                                // Signal-quality bucket from per-channel RMS, one update per
                                // window. Cheap and avoids needing the full CalibrationMetrics
                                // struct when not recording.
                                let quality = Self.signalQuality(of: window)
                                // Milestone B state source — always run regardless of
                                // adaptiveComplexityEnabled (shadow mode), same invariant as
                                // signalQuality/detectedAdaptation. Stub estimator returns nil
                                // immediately; the real one gates on shape/artifact internally.
                                let spectral = await spectralEstimatorRef.estimate(window: window)
                                await MainActor.run {
                                    var changed = false
                                    if self?.signalQuality != quality {
                                        self?.signalQuality = quality
                                        changed = true
                                    }
                                    if self?.detectedSpectralState != spectral {
                                        self?.detectedSpectralState = spectral
                                        changed = true
                                    }
                                    if changed {
                                        self?.applyAdaptiveGeneration()
                                    }
                                }

                                // The compact JEPA state is derived from the
                                // same validated live window that powers the
                                // classifier. Keep it in memory only when the
                                // distinct capture toggle is active.
                                let jepaCaptureEnabled = await MainActor.run {
                                    self?.jepaTransitionCaptureEnabled ?? false
                                }
                                if jepaCaptureEnabled,
                                   let state = JEPASpectralState(
                                       window: window,
                                       timestamp: Date().timeIntervalSince1970
                                   ) {
                                    jepaTransitionCaptureRef.ingest(state)
                                }

                                // Record window and compute metrics if in calibration mode
                                if isCalibrating, let recorder = recorder {
                                    await recorder.recordWindow(window)
                                    let calibMetrics = await MainActor.run { self?.computeCalibrationMetrics(window: window) }
                                    await MainActor.run {
                                        self?.calibrationWindowCount += 1
                                        self?.calibrationMetrics = calibMetrics
                                    }
                                }

                                let result = channel.send(window)
                                if result.droppedBufferedElement {
                                    await MainActor.run { self?.droppedWindowCount += 1 }
                                }
                            } else {
                                metrics.recordWindowing(durationMicros: elapsedMicros(since: started))
                            }
                        } catch let bci as BCIError {
                            metrics.recordError(bci)
                            await self?.setLastError(bci.description)
                        }
                    }
                    // Clean completion: for live, the Muse likely auto-powered
                    // off — fall through to retry/fallback. For synthetic,
                    // a clean exit means we're done.
                } catch let bci as BCIError {
                    metrics.recordError(bci)
                    await self?.setLastError(bci.description)
                } catch {
                    let bci = BCIError.streamFailed(reason: error.localizedDescription)
                    metrics.recordError(bci)
                    await self?.setLastError(bci.description)
                }
                await current.stream.stop()
                if Task.isCancelled { break }
                if current.acquisition == .synthetic { break }   // already at last resort

                // Live stream stopped (error or clean completion). Retry the
                // live source a few times — Muse S powers itself off after
                // ~30 s of poor signal and reconnects when contact returns,
                // and reconnecting beats a silent fallback to synthetic.
                // A productive attempt (≥256 samples ≈ 1 s of data) resets
                // the budget so transient hiccups don't accumulate.
                if samplesThisAttempt >= 256 { liveRetries = 0 }
                liveRetries += 1
                // Transport events are recorded independent of the
                // per-sample loop's local `recorder`/`isCalibrating`
                // (out of scope here), so fetch fresh.
                let (isCalibratingNow, recorderNow) = await MainActor.run {
                    (self?.isCalibrating ?? false, self?.calibrationRecorder)
                }
                if liveRetries > maxLiveRetries {
                    BCILog.pipeline.notice("Live stream exhausted \(maxLiveRetries) retries — falling back to synthetic")
                    if isCalibratingNow, let recorderNow {
                        await recorderNow.recordTransportEvent(
                            .fellBackToSynthetic, at: Date().timeIntervalSince1970,
                            detail: "exhausted \(maxLiveRetries) retries"
                        )
                    }
                    current = EEGStreamFactory.makeSynthetic()
                    liveRetries = 0
                    await MainActor.run { self?.isReconnecting = false }
                } else {
                    let backoff = min(8.0, pow(2.0, Double(liveRetries - 1)))
                    BCILog.pipeline.notice("Live stream interrupted (\(samplesThisAttempt) samples); retry \(liveRetries)/\(maxLiveRetries) after \(backoff)s")
                    if isCalibratingNow, let recorderNow {
                        await recorderNow.recordTransportEvent(
                            .stalled, at: Date().timeIntervalSince1970,
                            detail: "retry \(liveRetries)/\(maxLiveRetries) after \(backoff)s, \(samplesThisAttempt) samples this attempt"
                        )
                    }
                    await MainActor.run {
                        self?.isReconnecting = true
                        self?.signalQuality = .lost
                        self?.applyAdaptiveGeneration()
                    }
                    try? await Task.sleep(nanoseconds: UInt64(backoff * 1_000_000_000))
                    await MainActor.run { self?.isReconnecting = false }
                }
            }
            await current.stream.stop()
        }

        // ── window channel → classifier → smoother → composition (off-main)
        let classifierRef = self.classifier
        let smootherRef = self.smoother
        classifyTask = Task.detached(priority: .userInitiated) {
            [weak self, metrics = metricsRef, channel, composition, classifications] in
            for await window in channel.stream {
                if Task.isCancelled { break }
                let cStart = DispatchTime.now()
                let prediction: IntentPrediction
                do {
                    prediction = try await classifierRef.classify(window: window)
                    metrics.recordClassification(
                        durationMicros: elapsedMicros(since: cStart),
                        computeMode: classifierRef.computeMode
                    )
                } catch let bci as BCIError {
                    metrics.recordError(bci)
                    await self?.setLastError(bci.description)
                    continue
                } catch {
                    let bci = BCIError.classifierInferenceFailed(reason: error.localizedDescription)
                    metrics.recordError(bci)
                    await self?.setLastError(bci.description)
                    continue
                }
                // Broadcast the raw (pre-smoothing) prediction to diagnostic
                // subscribers before it enters the FSM/carousel path.
                classifications.send(prediction)
                let smoothed = await smootherRef.ingest(prediction)
                await composition.applyIntent(smoothed)
            }
        }
    }

    /// Sets `lastError` on the main actor. Invoked from the detached pipeline
    /// tasks via `await self?.setLastError(...)` rather than
    /// `MainActor.run { self?.lastError = ... }` — a direct isolated-method call
    /// hops to the main actor without tripping Swift 6 region isolation's
    /// "sending 'self' risks causing data races" on the closure capture (the
    /// closure would capture `self`, which the detached task also uses across
    /// later loop iterations).
    private func setLastError(_ description: String) { lastError = description }

    /// Drives `spokenLoop` toward the current toggle value, serialized through a
    /// single chained task so overlapping enable/disable events apply in order
    /// (a sync-start / async-stop race could otherwise orphan a running loop).
    private func reconcileSpokenGenerationLoop() {
        let previous = spokenLoopReconcile
        let shouldRun = spokenGenerationLoopEnabled
        spokenLoopReconcile = Task { [weak self] in
            _ = await previous?.value
            guard let self else { return }
            if shouldRun {
                await self.ensureSpokenLoopRunning()
            } else {
                await self.ensureSpokenLoopStopped()
            }
        }
    }

    /// Built lazily on first enable (not in `init`, so the adaptation closure
    /// captures a fully-initialized `self`). Steers generation with a
    /// **signal-quality-only** adaptation (`SignalQualityGenerationRules` — an
    /// electrode-contact / hardware-confidence bucket), deliberately NOT the
    /// combined `detectedAdaptation`, which folds in the heuristic spectral
    /// state; that keeps the loop's "not a brain read" caveat true.
    private func ensureSpokenLoopRunning() async {
        guard spokenLoop == nil else { return }
        let loop = SpokenGenerationLoop(
            generator: container.predictorResolved.generator,
            speaker: voiceOutput,
            adaptationProvider: { [weak self] in
                await MainActor.run {
                    SignalQualityGenerationRules.adaptation(for: self?.signalQuality)
                }
            }
        )
        spokenLoop = loop
        await loop.start()
    }

    private func ensureSpokenLoopStopped() async {
        await spokenLoop?.stop()
        spokenLoop = nil
    }

    /// Opt-in autostart override (default: no-op) for a scriptable, reproducible
    /// hypnagogic run — the co-development loop's launch hook. Set
    /// `NEURALCOMPOSE_HYPNAGOGIC_AUTOSTART=<style>[:<profile>]`, e.g.
    /// `dialectical:focused`, to enable the loop at launch WITHOUT the UI toggle.
    /// Every existing gate still holds: enabling flows through the same
    /// `reconcileHypnagogicLoop()` path, so the mic/speech auth prompt fires and
    /// the red cloud-egress banner shows while active. Unset ⇒ nothing happens.
    /// `NEURALCOMPOSE_INTERACTION_LOG=1` additionally enables local turn logging
    /// (ADR-005) so a scripted run captures `dialectic-turns-<day>.jsonl`.
    private func applyHypnagogicAutostartFromEnvironment() {
        let env = ProcessInfo.processInfo.environment
        if let log = env["NEURALCOMPOSE_INTERACTION_LOG"]?.lowercased(),
           log == "1" || log == "true" {
            interactionLoggingEnabled = true
        }
        guard let raw = env["NEURALCOMPOSE_HYPNAGOGIC_AUTOSTART"]?
            .trimmingCharacters(in: .whitespaces).lowercased(), !raw.isEmpty else { return }
        // Single token: mirror | focused | reflective | contemplative. Tolerate
        // the legacy "<style>:<profile>" form by taking the last segment
        // (`dialectical:reflective` → `reflective`, `mirror` → `mirror`).
        let token = String(raw.split(separator: ":").last ?? Substring(raw))
        guard let mode = HypnagogicMode(rawValue: token) else {
            BCILog.pipeline.notice(
                "hypnagogic autostart: unknown mode '\(raw, privacy: .public)' (want mirror|focused|reflective|contemplative), ignoring")
            return
        }
        hypnagogicMode = mode
        BCILog.pipeline.notice(
            "hypnagogic autostart: enabling \(mode.rawValue, privacy: .public) — cloud-egress banner shows while active")
        hypnagogicLoopEnabled = true   // → reconcileHypnagogicLoop() (auth prompt + banner)
    }

    /// Serializes hypnagogic-loop start/stop through a single chained task, same
    /// as `reconcileSpokenGenerationLoop`, so a fast toggle can't orphan a loop.
    private func reconcileHypnagogicLoop() {
        let previous = hypnagogicLoopReconcile
        let shouldRun = hypnagogicLoopEnabled
        hypnagogicLoopReconcile = Task { [weak self] in
            _ = await previous?.value
            guard let self else { return }
            if shouldRun {
                await self.ensureHypnagogicLoopRunning()
            } else {
                await self.ensureHypnagogicLoopStopped()
            }
        }
    }

    /// Built lazily on first enable. Constructs the on-device mic listener and
    /// the cloud `claude-cli` generator HERE (not in AppContainer) so the
    /// network-egress path is instantiated only when the user opts in. Requests
    /// mic + speech authorization first; if denied, flips the toggle back off.
    private func ensureHypnagogicLoopRunning() async {
        // Already running the requested mode? Nothing to do. A change tears the
        // old loop down first.
        if hypnagogicLoop != nil, hypnagogicLoopBuilt == hypnagogicMode { return }
        await ensureHypnagogicLoopStopped()

        let listener = HypnagogicListener()
        let granted = await listener.requestAuthorization()
        guard granted else {
            hypnagogicLoopEnabled = false   // @MainActor: safe to set directly
            return
        }
        // Re-check the toggle: authorization awaited, so the user may have
        // turned it back off in the meantime.
        guard hypnagogicLoopEnabled else { return }

        let loop: any HypnagogicRunnable
        if let profile = hypnagogicMode.profile {
            // Dialectical (focused/reflective/contemplative). Two cloud calls per
            // turn (one per role). The gloss reads the current spectral state as a
            // heuristic BIAS (never a decoder); turn logging is gated on the
            // interaction-log opt-in, resolved at build time (toggling it mid-loop
            // takes effect on the next rebuild).
            //
            // All three profiles are WAKING, so the loop runs the waking role set
            // + a lucid waking system prompt — a coherent exchange, not sleep
            // onset. The sleep-mirror roles/prompt stay reserved for the future
            // wind-down / hypnagogic / dream rungs on the mode ladder.
            let turnLogger: any DialecticalTurnLogging =
                (interactionLoggingEnabled ? (interactionLogger as? any DialecticalTurnLogging) : nil)
                ?? NullDialecticalTurnLogger()
            loop = HypnagogicDialecticLoop(
                listener: listener,
                generator: ClaudeCLIGenerator(
                    systemPrompt: ClaudeCLIGenerator.wakingDialecticalSystemPrompt
                ),
                speaker: voiceOutput,
                embedder: container.sentenceEmbedder,
                roles: DialecticalRole.wakingRoles,
                tuning: profile.tuning,
                glossProvider: { [weak self] in await self?.currentSpectralGlossState() ?? nil },
                turnLogger: turnLogger,
                config: profile.loopConfig()
            )
        } else {
            // Mirror — the plain, non-competing reply loop (one cloud call/turn).
            loop = HypnagogicDialogueLoop(
                listener: listener,
                generator: ClaudeCLIGenerator(),
                speaker: voiceOutput
            )
        }
        hypnagogicLoop = loop
        hypnagogicLoopBuilt = hypnagogicMode
        // Forward this loop's spoken-node events into the stable relay the 3D
        // workspace subscribes to (Stage 1d). Only the dialectic loop emits
        // them; the mirror loop leaves the relay quiet.
        spokenNodeForwardTask?.cancel()
        if let dialectic = loop as? HypnagogicDialecticLoop {
            let relay = spokenNodeRelay
            let events = dialectic.spokenNodeStream()
            spokenNodeForwardTask = Task { for await event in events { relay.send(event) } }
        }
        await loop.start()
    }

    private func ensureHypnagogicLoopStopped() async {
        spokenNodeForwardTask?.cancel()
        spokenNodeForwardTask = nil
        await hypnagogicLoop?.stop()
        hypnagogicLoop = nil
        hypnagogicLoopBuilt = nil
    }

    /// The latest spectral-state gloss for the dialectic loop's fast biological
    /// clock, read on the main actor. A heuristic bias signal, never a cognitive
    /// read (see `SpectralState.honestyCaveat`).
    private func currentSpectralGlossState() -> SpectralState? { detectedSpectralState }

    /// Assembles a `HealthSnapshot` from the resolved backend kinds, the pipeline
    /// mode, EEG throughput, and the dialectic loop's turn liveness. Read-only —
    /// the watchdog observes runtime state, never changes it.
    private func assembleHealthSnapshot(now: Date, uptime: Double,
                                        windowsPerSecond wps: Double,
                                        expectedLive: Bool) async -> HealthSnapshot {
        let mode = pipelineMode
        let estimatorKind = container.spectralEstimatorResolved.kind.rawValue
        let embedderKind = container.sentenceEmbedderKind
        let predictorKind = container.predictorResolved.kind.rawValue
        let classifierKind = container.classifierResolved.kind.rawValue

        var turnCount: Int?
        var lastTurnAt: Date?
        if let dialectic = hypnagogicLoop as? HypnagogicDialecticLoop {
            turnCount = await dialectic.turnIndex
            lastTurnAt = await dialectic.lastTurnAt
        }
        let loopRunning = hypnagogicLoop != nil
        let secondsSinceLastTurn = lastTurnAt.map { now.timeIntervalSince($0) }

        // Gloss stuck: a live MLX estimator that still produces no state while
        // windows are flowing (past warmup) — the exact failure that hid behind
        // glossScalar == 0.5 all night.
        let state = detectedSpectralState
        let glossStuck = estimatorKind == "mlx" && state == nil && wps > 0 && uptime > 8

        let degraded = HealthSnapshot.degradedReasons(
            acquisition: mode.acquisition.rawValue, expectedLive: expectedLive,
            estimatorKind: estimatorKind, embedderKind: embedderKind,
            predictorKind: predictorKind, classifierKind: classifierKind,
            windowsPerSecond: wps, uptimeSeconds: uptime,
            glossStuck: glossStuck, loopRunning: loopRunning,
            secondsSinceLastTurn: secondsSinceLastTurn)

        return HealthSnapshot(
            timestamp: now, uptimeSeconds: uptime,
            acquisition: mode.acquisition.rawValue, transport: mode.transport.rawValue,
            signalQuality: signalQuality.map { String(describing: $0) }, windowsPerSecond: wps,
            estimatorKind: estimatorKind, embedderKind: embedderKind,
            predictorKind: predictorKind, classifierKind: classifierKind,
            fullyLive: mode.isFullyLive, substitutionSummary: mode.substitutionSummary,
            spectralState: state?.badgeLabel, glossStuck: glossStuck,
            loopMode: hypnagogicLoopBuilt?.rawValue, loopRunning: loopRunning,
            turnCount: turnCount, secondsSinceLastTurn: secondsSinceLastTurn,
            degraded: degraded)
    }

    public func stop() async {
        // Always silence the experimental spoken loop, even when the pipeline
        // itself isn't running — its lifecycle is independent of `isRunning`.
        if spokenGenerationLoopEnabled { spokenGenerationLoopEnabled = false }
        if hypnagogicLoopEnabled { hypnagogicLoopEnabled = false }
        guard isRunning else { return }
        await stopCalibrationRecording()
        await stopImaginedSpeechSession()
        if isDictating { await voiceInput.cancelRecording(); isDictating = false }
        await voiceOutput.stopSpeaking()
        streamTask?.cancel();   streamTask = nil
        classifyTask?.cancel(); classifyTask = nil
        carouselTask?.cancel(); carouselTask = nil
        metricsTask?.cancel();  metricsTask = nil
        healthTask?.cancel();   healthTask = nil
        snapshotTask?.cancel(); snapshotTask = nil

        // Finish channels so any straggling iterators terminate cleanly.
        windowChannel?.finish()
        windowChannel = nil
        sampleChannel?.finish()
        sampleChannel = nil
        classifierChannel?.finish()
        classifierChannel = nil
        if let c = composition { await c.finish() }
        composition = nil

        isRunning = false
    }

    /// Returns a fresh `AsyncStream<EEGSample>` that replays the same samples
    /// the production pipeline is consuming. Each call registers an
    /// independent subscriber, so multiple consumers can call this
    /// concurrently and each receives every sample.
    ///
    /// **Single-owner invariant.** `AppViewModel` is the canonical owner
    /// of the active EEG stream. Live BrainFlow sessions are
    /// single-consumer — only `AppViewModel.start()` calls
    /// `EEGStreaming.start()`. Visualization consumers (the plotter, the
    /// channel-health provider) receive replicated samples through this
    /// broadcast fan-out, not by calling `.start()` themselves. Calling
    /// `EEGStreaming.start()` a second time on a live `BrainFlowService`
    /// would open a second BLE/BrainFlow session and clobber the
    /// supervisor's `pollTask` — do not do it.
    ///
    /// The returned stream:
    /// - is one subscriber of an `AsyncMulticastChannel<EEGSample>`; each
    ///   subscriber has its own capacity-8 drop-oldest buffer, so one slow
    ///   consumer can lag briefly without stalling the supervisor or
    ///   starving the other consumers;
    /// - is finished when `stop()` runs;
    /// - returns an already-finished stream if `start()` has not yet run
    ///   (e.g. the debug window is opened before the pipeline is up).
    public func liveSampleStream() -> AsyncStream<EEGSample> {
        sampleChannel?.subscribe() ?? AsyncStream<EEGSample> { $0.finish() }
    }

    /// Raw (pre-smoothing) classifier output, broadcast independently of the
    /// FSM/carousel path — see `classifierChannel`. Diagnostic use only
    /// (e.g. the 3D workspace visualizer); the production intent pipeline
    /// does not read from this.
    public func liveClassifierStream() -> AsyncStream<IntentPrediction> {
        classifierChannel?.subscribe() ?? AsyncStream<IntentPrediction> { $0.finish() }
    }

    /// Spoken-node events from the active dialectic loop (Stage 1d) — the
    /// grounding signal the 3D workspace consumes to place + light concept
    /// nodes per voiced word. A stable relay: subscribing once survives loop
    /// mode changes and rebuilds, and stays quiet (but live) when no dialectic
    /// is running. Diagnostic/visualization only; on-device.
    public func spokenNodeStream() -> AsyncStream<SpokenNodeEvent> {
        spokenNodeRelay.subscribe()
    }

    public func resetComposition(seed: String = "") async {
        await composition?.reset(to: seed)
    }

    /// Parameterless overload of `resetComposition(seed:)` so that
    /// `AppCommandDispatchTarget` (which declares
    /// `func resetComposition() async`) is satisfied without forcing
    /// the protocol to grow a default parameter (which Swift does not
    /// allow in protocol declarations). The dispatcher uses this
    /// overload; the seed-bearing form is still available for callers
    /// that want to seed the composition with non-empty text.
    public func resetComposition() async {
        await resetComposition(seed: "")
    }

    // MARK: - Calibration

    public func startCalibrationRecording() async {
        guard isRunning else { return }
        let recorder = CalibrationRecorder()
        let recordingsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NeuralCompose")
            .appendingPathComponent("Recordings")
        do {
            try FileManager.default.createDirectory(at: recordingsURL, withIntermediateDirectories: true)
            let profile = container.streamResolved.profile
            let sampleRate = container.streamResolved.stream.effectiveSampleRate
            try await recorder.beginSession(to: recordingsURL, profile: profile, sampleRate: sampleRate)
            self.calibrationRecorder = recorder
            isCalibrating = true
            calibrationWindowCount = 0
            calibrationSampleRate = 0
            droppedWindowCount = 0
            calibrationMetrics = nil
        } catch {
            lastError = "Failed to start calibration: \(error.localizedDescription)"
        }
    }

    public func stopCalibrationRecording() async {
        guard isCalibrating else { return }
        if let recorder = calibrationRecorder {
            await recorder.finishSession()
            self.calibrationRecorder = nil
        }
        isCalibrating = false
    }

    public func startStickyLabel(_ label: CalibrationLabel) async {
        guard let recorder = calibrationRecorder else { return }
        let now = Date().timeIntervalSince1970   // EEG samples use Unix epoch; events must match
        await recorder.startStickyLabel(label, at: now)
    }

    public func endStickyLabel() async {
        guard let recorder = calibrationRecorder else { return }
        let now = Date().timeIntervalSince1970   // EEG samples use Unix epoch; events must match
        await recorder.endStickyLabel(at: now)
    }

    public func addTimedEvent(_ label: CalibrationLabel) async {
        guard let recorder = calibrationRecorder else { return }
        let now = Date().timeIntervalSince1970   // EEG samples use Unix epoch; events must match
        await recorder.addTimedEvent(label, at: now)
    }

    // MARK: - Track B (Imagined Speech)

    /// Start a Track B session: open the recorder, start the protocol, and
    /// spin up two consumer tasks — one that mirrors protocol state into the
    /// @Published properties (UI), one that forwards the same state to the
    /// recorder (data). Both consume separate iterations of the same
    /// AsyncStream so neither blocks the other.
    public func startImaginedSpeechSession() async {
        guard isRunning, !isImaginedSpeechRecording else { return }
        let recorder = TrackBRecorder()
        let rootURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NeuralCompose")
            .appendingPathComponent("Calibration")
            .appendingPathComponent(TrackBRecorder.directoryName)
        do {
            try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        } catch {
            lastError = "Failed to create Track B directory: \(error.localizedDescription)"
            return
        }

        let profile = container.streamResolved.profile
        let sampleRate = container.streamResolved.stream.effectiveSampleRate
        let config = ImaginedSpeechProtocol.Config()
        let proto = ImaginedSpeechProtocol(config: config)
        let seed = proto.orderSeed

        let url: URL
        do {
            url = try await recorder.beginSession(
                root: rootURL,
                profile: profile,
                sampleRate: sampleRate,
                protocolConfig: config,
                protocolSeed: seed
            )
        } catch {
            lastError = "Failed to start Track B recorder: \(error.localizedDescription)"
            return
        }

        self.trackBRecorder = recorder
        self.imaginedProtocol = proto
        self.imaginedSessionURL = url
        self.imaginedActiveSampleCount = 0
        self.imaginedDroppedSampleCount = 0
        self.imaginedSpeechState = ImaginedSpeechProtocolState(
            phase: .idle, target: nil, trialIndex: 0, totalTrials: config.totalTrials,
            phaseStartTimestamp: Date().timeIntervalSince1970,
            phaseDuration: 0, timeRemaining: 0
        )
        self.isImaginedSpeechRecording = true

        // Single consumer of the protocol's state stream: updates UI AND
        // forwards to the recorder. Doing it in one task guarantees the
        // recorder sees phase changes in the same order the UI does — no
        // chance of the recorder closing a trial window before the UI knows
        // about it (or vice versa).
        let states = proto.states
        imaginedProtocolTask = Task { [weak self] in
            for await state in states {
                let snapshot = state
                await MainActor.run {
                    self?.imaginedSpeechState = snapshot
                }
                if let recorder = await MainActor.run(body: { self?.trackBRecorder }) {
                    await recorder.markPhase(snapshot)
                }
                if snapshot.phase == .finished {
                    await self?.stopImaginedSpeechSession()
                    return
                }
            }
        }

        // 2 Hz poll of recorder counters so the UI's "active samples / dropped"
        // displays stay alive without the recorder publishing them itself.
        imaginedStatsTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 500_000_000)
                if Task.isCancelled { break }
                guard let recorder = await MainActor.run(body: { self?.trackBRecorder }) else { return }
                let active = await recorder.activeSampleCount
                let dropped = await recorder.droppedSampleCount
                await MainActor.run {
                    self?.imaginedActiveSampleCount = active
                    self?.imaginedDroppedSampleCount = dropped
                }
            }
        }

        await proto.start()
    }

    public func stopImaginedSpeechSession() async {
        guard isImaginedSpeechRecording else { return }
        if let proto = imaginedProtocol {
            await proto.stop()
        }
        imaginedProtocolTask?.cancel(); imaginedProtocolTask = nil
        imaginedStatsTask?.cancel();    imaginedStatsTask = nil
        if let recorder = trackBRecorder {
            await recorder.finishSession()
            let active = await recorder.activeSampleCount
            let dropped = await recorder.droppedSampleCount
            self.imaginedActiveSampleCount = active
            self.imaginedDroppedSampleCount = dropped
        }
        self.trackBRecorder = nil
        self.imaginedProtocol = nil
        self.isImaginedSpeechRecording = false
    }

    // MARK: - Voice I/O

    /// Begins push-to-talk dictation. Requests mic/speech authorization on
    /// first use (not at app launch — see `VoiceInputFactory.live()`'s doc
    /// comment), then opens the mic. Call on button-press.
    public func startDictation() async {
        guard !isDictating, composition != nil else { return }
        let granted = await voiceInput.requestAuthorization()
        guard granted else {
            voiceWarning = "Microphone/speech access not granted"
            return
        }
        do {
            try await voiceInput.startRecording()
            isDictating = true
        } catch {
            voiceWarning = "Dictation unavailable: \(error.localizedDescription)"
        }
    }

    /// Ends push-to-talk dictation, merging the final transcript into the
    /// same composition buffer EEG commits populate. Call on button-release.
    public func stopDictation() async {
        guard isDictating else { return }
        defer { isDictating = false }
        do {
            let finalText = try await voiceInput.stopRecording()
            if let composition {
                await composition.appendExternalText(finalText, source: .dictation)
            }
        } catch {
            voiceWarning = "Dictation failed: \(error.localizedDescription)"
        }
    }

    /// Begins push-to-talk voice command listening. Requests
    /// mic/speech authorization on first use (not at app launch —
    /// see `VoiceCommandFactory.live()`'s doc comment), then opens
    /// the mic. Call on button-press. The recognizer is *not* the
    /// dictation service; this is a separate `SFSpeechRecognizer`
    /// instance dedicated to commands, so the user can hold the
    /// "Hold to Command" button without affecting "Hold to Talk".
    public func startCommandListening() async {
        guard !isCommanding else { return }
        let granted = await voiceCommandInput.requestAuthorization()
        guard granted else {
            commandWarning = "Microphone/speech access not granted"
            return
        }
        do {
            try await voiceCommandInput.startCommand()
            isCommanding = true
        } catch {
            commandWarning = "Voice commands unavailable: \(error.localizedDescription)"
        }
    }

    /// Ends push-to-talk voice command listening. The final
    /// transcript is parsed by the configured recognizer and, on a
    /// successful match, the resulting `AppCommand` is dispatched
    /// through the same `AppCommandDispatcher` the palette and
    /// menus use. On a no-match, sets `commandWarning`. Call on
    /// button-release.
    public func stopCommandListening() async {
        guard isCommanding else { return }
        defer { isCommanding = false }
        do {
            // `stopAndRecognize()` combines the mic teardown +
            // parser invocation + diagnostic record construction
            // in one call (see SpeechCommandRecognizerService's
            // doc comment). The parser closure was captured at
            // init() time.
            let (command, result) = try await voiceCommandInput.stopAndRecognize()
            // Diagnostic log for every recognition attempt. Mirrors
            // the existing voice-dictation log pattern (see
            // `BCILog.voice.notice` calls in `VoiceCommandFactory`).
            // This becomes the dataset for evaluating fuzzy /
            // embedding recognizers — every transcript is a labeled
            // example (transcript -> command, or transcript ->
            // rejection).
            BCILog.voice.notice("voice command recognition: transcript=\(result.transcript) command=\(result.command?.id ?? "nil") rejection=\(result.rejectionReason?.rawValue ?? "none")")
            if let command, let dispatcher = commandDispatcher {
                await dispatcher.perform(command)
            } else if result.command == nil {
                commandWarning = "Couldn't recognize that command"
            }
        } catch {
            commandWarning = "Voice command failed: \(error.localizedDescription)"
        }
    }

    /// Cancels an in-flight voice command utterance without
    /// dispatching. Mirrors `stopDictation()`'s "release without
    /// commit" path; called when the user releases the button but
    /// the recognizer hasn't produced a final transcript (e.g. an
    /// empty utterance).
    public func cancelCommandListening() async {
        guard isCommanding else { return }
        defer { isCommanding = false }
        await voiceCommandInput.cancelCommand()
    }

    /// Reads the current composed sentence aloud. Explicit-trigger only —
    /// never invoked automatically on word commit.
    public func speak() async {
        guard !isSpeaking, !composedText.isEmpty else { return }
        isSpeaking = true
        defer { isSpeaking = false }
        do {
            try await voiceOutput.speak(composedText)
        } catch {
            voiceWarning = "Speech failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Semantic Dialectic Engine

    /// Runs the three-pass thesis/antithesis/synthesis refinement over the
    /// current composed sentence. Explicit-trigger only — see
    /// `DialecticEngine`'s doc comment for why this never runs
    /// automatically.
    public func refineComposedText() async {
        guard !isRefining, !composedText.isEmpty else { return }
        isRefining = true
        defer { isRefining = false }
        do {
            refinementSuggestion = try await dialecticEngine.refine(composedText)
        } catch is CancellationError {
            // no-op
        } catch {
            refinementWarning = "Refinement failed: \(error.localizedDescription)"
        }
    }

    /// Accepts the current suggestion's synthesis as the new composed text
    /// — a replace, not an append (see
    /// `TextCompositionController.applyRefinement`).
    public func acceptRefinement() async {
        guard let refinement = refinementSuggestion, let composition else { return }
        await composition.applyRefinement(refinement.synthesis)
        refinementSuggestion = nil
    }

    /// Discards the current suggestion without changing composed text.
    public func dismissRefinement() {
        refinementSuggestion = nil
    }

    // MARK: - Helpers

    /// Recomputes `detectedAdaptation` from live `signalQuality`/
    /// `detectedSpectralState` unconditionally (so the badge is informative
    /// even in shadow mode), then pushes it to the composition controller
    /// only if `adaptiveComplexityEnabled` and only if it actually changed.
    /// Call after every `signalQuality`/`detectedSpectralState` write.
    private func applyAdaptiveGeneration() {
        let detected = AdaptiveGenerationCombination.adaptation(
            signalQuality: signalQuality, spectralState: detectedSpectralState
        )
        detectedAdaptation = detected
        let applied = adaptiveComplexityEnabled ? detected : .raw
        guard applied != appliedAdaptation else { return }
        appliedAdaptation = applied
        Task { [composition] in await composition?.updateGenerationAdaptation(applied) }
    }

    private func computeCalibrationMetrics(window: EEGWindow) -> CalibrationMetrics {
        let channelLabels = container.streamResolved.profile.channelLabels.isEmpty
            ? ["ch0", "ch1", "ch2", "ch3"]
            : container.streamResolved.profile.channelLabels

        var rms: [Float] = []
        var peak: [Float] = []

        for ch in window.samples {
            let samples = ch
            let sumSq = samples.reduce(0.0) { $0 + Float($1 * $1) }
            let rmsVal = sqrt(sumSq / Float(samples.count))
            let peakVal = samples.map(abs).max() ?? 0
            rms.append(rmsVal)
            peak.append(peakVal)
        }

        return CalibrationMetrics(
            channelCount: window.channelCount,
            channelLabels: channelLabels,
            rms: rms,
            peak: peak,
            samplesPerSec: window.sampleRate
        )
    }

    /// Bucket per-channel RMS into healthy/poor/lost. A channel counts as
    /// "in range" when its RMS sits in 5–200 µV; below = electrode lifted or
    /// dry pad, above = muscle / mains interference.
    private nonisolated static func signalQuality(of window: EEGWindow) -> SignalQuality {
        var inRange = 0
        for ch in window.samples {
            let n = Float(ch.count)
            if n == 0 { continue }
            // Real EEG (e.g. Muse over OSC / Mind Monitor) carries a large
            // per-channel DC baseline (~800µV) that synthetic data never had.
            // Subtract it so RMS measures the AC signal amplitude, not the
            // offset — otherwise every channel sits far above the 200µV ceiling
            // and a perfectly good stream is misreported as `.lost`.
            var mean: Float = 0
            for v in ch { mean += v }
            mean /= n
            var sumSq: Float = 0
            for v in ch { let d = v - mean; sumSq += d * d }
            let rms = (sumSq / n).squareRoot()
            if rms >= 5 && rms <= 200 { inRange += 1 }
        }
        switch inRange {
        case 3...: return .healthy
        case 1...2: return .poor
        default:    return .lost
        }
    }

    /// Publishes `viewModel.pipelineMode`, called at the top of every
    /// supervisor loop iteration (initial start and every retry). Must
    /// compute `transportDetail` the same way `AppContainer.pipelineMode`
    /// does — this is the value that's actually displayed once the app is
    /// running, so if this doesn't compute it, nothing does: the initial
    /// `viewModel.pipelineMode` set from `container.pipelineMode` gets
    /// overwritten by this on the very first loop iteration, before OSC's
    /// diagnostics (bound port, interface) even have a chance to populate.
    private nonisolated static func publishMode(
        current: EEGStreamFactory.Resolved,
        container: AppContainer,
        on viewModel: AppViewModel?
    ) async {
        let mode = PipelineMode(
            acquisition: current.acquisition,
            transport: current.transport,
            sourceProfile: current.profile,
            classifier: container.classifierResolved.kind,
            predictor: container.predictorResolved.kind,
            transportDetail: AppContainer.transportDetail(for: current.stream)
        )
        await MainActor.run { viewModel?.pipelineMode = mode }
    }

    private func apply(snapshot snap: TextCompositionController.Snapshot) {
        // Captured before overwriting: `self.composedText`/`lastCommittedWord`
        // still hold the *previous* snapshot's values here, which is exactly
        // "the context right before this commit" — TextCompositionController
        // itself never exposes a pre-commit string, so this is reconstructed
        // from the snapshot stream rather than threading a new parameter
        // through BCICore.
        let previousComposedText = self.composedText
        let previousCommittedWord = self.lastCommittedWord
        let previousCommitSequence = self.lastCommitSequence

        self.composedText = snap.composedText
        self.candidates = snap.candidates
        self.highlightIndex = snap.highlightIndex
        self.isPredicting = snap.isPredicting
        self.lastCommittedWord = snap.lastCommittedWord
        self.lastCommitSequence = snap.commitSequence

        guard let event = Self.telemetryEvent(
            previousComposedText: previousComposedText,
            previousCommitSequence: previousCommitSequence,
            snapshot: snap,
            signalQuality: signalQuality,
            detectedSpectralState: detectedSpectralState,
            appliedAdaptation: appliedAdaptation,
            adaptiveComplexityEnabled: adaptiveComplexityEnabled
        ) else { return }

        if interactionLoggingEnabled {
            let logger = interactionLogger
            Task { await logger.log(event) }
        }
        if jepaTransitionCaptureEnabled {
            _ = jepaTransitionCapture.recordTransition(
                actionVector: JEPAActionEncoder.vector(for: appliedAdaptation)
            )
        }
    }

    /// Pure: given the snapshot stream's before/after state plus the
    /// currently-published BCI context, decides whether this snapshot
    /// represents a genuine new word commit and, if so, builds the event to
    /// log — `nil` on carousel ticks/prediction refreshes that don't change
    /// `lastCommittedWord`. Kept free of `self`/`interactionLoggingEnabled`
    /// so it's unit-testable with plain values, no pipeline or actor
    /// required (see `Tests/NeuralComposeAppTests/AppViewModelTelemetryTests.swift`).
    /// Logs the classified `SpectralState` badge label, never the raw
    /// embedding (see `TelemetryEvent`'s doc comment), and whatever
    /// adaptation was actually in effect (`appliedAdaptation`, `.raw` unless
    /// `adaptiveComplexityEnabled`), not just what was detected.
    ///
    /// Compares `commitSequence`, not `lastCommittedWord`'s text — two
    /// genuine, temporally-distinct commits of the same word (e.g.
    /// committing "the" twice in a row) are a real, legitimate case that a
    /// text-equality check cannot distinguish from "no new commit
    /// happened," silently dropping the second one.
    nonisolated static func telemetryEvent(
        previousComposedText: String,
        previousCommitSequence: UInt64,
        snapshot: TextCompositionController.Snapshot,
        signalQuality: SignalQuality?,
        detectedSpectralState: SpectralState?,
        appliedAdaptation: GenerationAdaptation,
        adaptiveComplexityEnabled: Bool
    ) -> TelemetryEvent? {
        guard let committed = snapshot.lastCommittedWord, snapshot.commitSequence != previousCommitSequence else {
            return nil
        }
        return TelemetryEvent(
            composedContextBeforeCommit: previousComposedText,
            committedWord: committed,
            signalQuality: signalQuality.map(String.init(describing:)),
            detectedSpectralState: detectedSpectralState?.badgeLabel,
            appliedMaxCandidates: appliedAdaptation.maxCandidates,
            appliedTemperature: appliedAdaptation.temperature,
            appliedStyleInstruction: appliedAdaptation.styleInstruction,
            adaptiveComplexityEnabled: adaptiveComplexityEnabled
        )
    }
}

@inline(__always)
private func elapsedMicros(since start: DispatchTime) -> UInt64 {
    let now = DispatchTime.now()
    return (now.uptimeNanoseconds &- start.uptimeNanoseconds) / 1_000
}
