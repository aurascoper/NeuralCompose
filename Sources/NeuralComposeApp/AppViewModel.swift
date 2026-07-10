import Foundation
import SwiftUI
import Combine
import BCICore
import BCIEEG
import BCIClassifier
import BCILLM

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
@MainActor
public final class AppViewModel: ObservableObject {

    // ── Published state ──────────────────────────────────────────────────
    @Published public private(set) var composedText: String = ""
    @Published public private(set) var candidates: [PredictedWord] = []
    @Published public private(set) var highlightIndex: Int = 0
    @Published public private(set) var isPredicting: Bool = false
    @Published public private(set) var lastCommittedWord: String?
    @Published public private(set) var pipelineMode: PipelineMode
    @Published public private(set) var lastError: String?
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

    // ── Track B (imagined speech) — additive, never touches Track A state ─
    @Published public private(set) var isImaginedSpeechRecording: Bool = false
    @Published public private(set) var imaginedSpeechState: ImaginedSpeechProtocolState = .init(
        phase: .idle, target: nil, trialIndex: 0, totalTrials: 0,
        phaseStartTimestamp: 0, phaseDuration: 0, timeRemaining: 0
    )
    @Published public private(set) var imaginedActiveSampleCount: Int = 0
    @Published public private(set) var imaginedDroppedSampleCount: Int = 0
    @Published public private(set) var imaginedSessionURL: URL?

    // ── Immutable wiring (lives for the lifetime of the view model) ──────
    public let container: AppContainer
    private let metrics: MetricsCollector
    private let windowing: EEGWindowing
    private let smoother: IntentSmoother
    private let classifier: any IntentClassifying
    private let predictor: any NextWordPredicting

    // ── Per-start resources (recreated each call to start()) ─────────────
    private var composition: TextCompositionController?
    private var windowChannel: BoundedAsyncChannel<EEGWindow>?
    /// Internal fan-out for raw `EEGSample`s. Created in `start()`, finished
    /// in `stop()`. See the doc comment on `liveSampleStream()` for the
    /// single-owner invariant this field enforces.
    private var sampleChannel: BoundedAsyncChannel<EEGSample>?
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

    public init(container: AppContainer) {
        self.container = container
        self.metrics = container.metrics
        self.classifier = container.classifierResolved.classifier
        self.predictor = container.predictorResolved.predictor
        self.pipelineMode = container.pipelineMode
        self.computeMode = container.classifierResolved.computeMode
        self.windowing = EEGWindowing(config: container.windowingConfig)
        self.smoother = IntentSmoother(config: container.smootherConfig)
        self.metricsSnapshot = container.metrics.snapshot()
        if let w = container.classifierResolved.warning {
            self.lastError = w
        } else if let w = container.predictorResolved.warning {
            self.lastError = w
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
        // Internal fan-out of raw samples. Capacity 8 with dropOldest keeps
        // a recent history available for visualization consumers; the
        // production classifier reads from `channel` (windows), not from
        // here.
        let samples = BoundedAsyncChannel<EEGSample>(capacity: 8, overflow: .dropOldest)
        let composition = TextCompositionController(predictor: predictor, metrics: metrics)
        self.windowChannel = channel
        self.sampleChannel = samples
        self.composition = composition
        await composition.start()

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

        // ── EEG supervisor (off-main): start the configured stream; if it
        //    errors or completes and we aren't already on synthetic, fall
        //    back and keep going. Updates `pipelineMode` on the way.
        let initialResolved = container.streamResolved
        let containerRef = container
        streamTask = Task.detached(priority: .userInitiated) {
            [weak self, windowing, metrics = metricsRef, channel, samples] in
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
                                await MainActor.run {
                                    if self?.signalQuality != quality {
                                        self?.signalQuality = quality
                                    }
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
                            await MainActor.run { self?.lastError = bci.description }
                        }
                    }
                    // Clean completion: for live, the Muse likely auto-powered
                    // off — fall through to retry/fallback. For synthetic,
                    // a clean exit means we're done.
                } catch let bci as BCIError {
                    metrics.recordError(bci)
                    await MainActor.run { self?.lastError = bci.description }
                } catch {
                    let bci = BCIError.streamFailed(reason: error.localizedDescription)
                    metrics.recordError(bci)
                    await MainActor.run { self?.lastError = bci.description }
                }
                await current.stream.stop()
                if Task.isCancelled { break }
                if current.source == .synthetic { break }   // already at last resort

                // Live stream stopped (error or clean completion). Retry the
                // live source a few times — Muse S powers itself off after
                // ~30 s of poor signal and reconnects when contact returns,
                // and reconnecting beats a silent fallback to synthetic.
                // A productive attempt (≥256 samples ≈ 1 s of data) resets
                // the budget so transient hiccups don't accumulate.
                if samplesThisAttempt >= 256 { liveRetries = 0 }
                liveRetries += 1
                if liveRetries > maxLiveRetries {
                    BCILog.pipeline.notice("Live stream exhausted \(maxLiveRetries) retries — falling back to synthetic")
                    current = EEGStreamFactory.makeSynthetic()
                    liveRetries = 0
                    await MainActor.run { self?.isReconnecting = false }
                } else {
                    let backoff = min(8.0, pow(2.0, Double(liveRetries - 1)))
                    BCILog.pipeline.notice("Live stream interrupted (\(samplesThisAttempt) samples); retry \(liveRetries)/\(maxLiveRetries) after \(backoff)s")
                    await MainActor.run {
                        self?.isReconnecting = true
                        self?.signalQuality = .lost
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
            [weak self, metrics = metricsRef, channel, composition] in
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
                    await MainActor.run { self?.lastError = bci.description }
                    continue
                } catch {
                    let bci = BCIError.classifierInferenceFailed(reason: error.localizedDescription)
                    metrics.recordError(bci)
                    await MainActor.run { self?.lastError = bci.description }
                    continue
                }
                let smoothed = await smootherRef.ingest(prediction)
                await composition.applyIntent(smoothed)
            }
        }
    }

    public func stop() async {
        guard isRunning else { return }
        await stopCalibrationRecording()
        await stopImaginedSpeechSession()
        streamTask?.cancel();   streamTask = nil
        classifyTask?.cancel(); classifyTask = nil
        carouselTask?.cancel(); carouselTask = nil
        metricsTask?.cancel();  metricsTask = nil
        snapshotTask?.cancel(); snapshotTask = nil

        // Finish channels so any straggling iterators terminate cleanly.
        windowChannel?.finish()
        windowChannel = nil
        sampleChannel?.finish()
        sampleChannel = nil
        if let c = composition { await c.finish() }
        composition = nil

        isRunning = false
    }

    /// Returns an `AsyncStream<EEGSample>` that replays the same samples
    /// the production pipeline is consuming.
    ///
    /// **Single-owner invariant.** `AppViewModel` is the canonical owner
    /// of the active EEG stream. Live BrainFlow sessions are
    /// single-consumer — only `AppViewModel.start()` calls
    /// `EEGStreaming.start()`. Visualization consumers (the plotter, the
    /// channel-health provider) receive replicated samples through this
    /// fan-out, not by calling `.start()` themselves. Calling
    /// `EEGStreaming.start()` a second time on a live `BrainFlowService`
    /// would open a second BLE/BrainFlow session and clobber the
    /// supervisor's `pollTask` — do not do it.
    ///
    /// The returned stream:
    /// - is backed by a `BoundedAsyncChannel<EEGSample>` (capacity 8,
    ///   drop-oldest) so visualization can lag briefly without stalling
    ///   the supervisor;
    /// - is finished when `stop()` runs;
    /// - returns an already-finished stream if `start()` has not yet run
    ///   (e.g. the debug window is opened before the pipeline is up).
    public func liveSampleStream() -> AsyncStream<EEGSample> {
        sampleChannel?.stream ?? AsyncStream<EEGSample> { $0.finish() }
    }

    public func resetComposition(seed: String = "") async {
        await composition?.reset(to: seed)
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

    // MARK: - Helpers

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
            var sumSq: Float = 0
            for v in ch { sumSq += v * v }
            let rms = (sumSq / n).squareRoot()
            if rms >= 5 && rms <= 200 { inRange += 1 }
        }
        switch inRange {
        case 3...: return .healthy
        case 1...2: return .poor
        default:    return .lost
        }
    }

    private nonisolated static func publishMode(
        current: EEGStreamFactory.Resolved,
        container: AppContainer,
        on viewModel: AppViewModel?
    ) async {
        let mode = PipelineMode(
            source: current.source,
            sourceProfile: current.profile,
            classifier: container.classifierResolved.kind,
            predictor: container.predictorResolved.kind
        )
        await MainActor.run { viewModel?.pipelineMode = mode }
    }

    private func apply(snapshot snap: TextCompositionController.Snapshot) {
        self.composedText = snap.composedText
        self.candidates = snap.candidates
        self.highlightIndex = snap.highlightIndex
        self.isPredicting = snap.isPredicting
        self.lastCommittedWord = snap.lastCommittedWord
    }
}

@inline(__always)
private func elapsedMicros(since start: DispatchTime) -> UInt64 {
    let now = DispatchTime.now()
    return (now.uptimeNanoseconds &- start.uptimeNanoseconds) / 1_000
}
