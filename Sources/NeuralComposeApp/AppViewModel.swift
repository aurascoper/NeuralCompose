import Foundation
import SwiftUI
import Combine
import BCICore
import BCIEEG
import BCIClassifier
import BCILLM

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
        let composition = TextCompositionController(predictor: predictor, metrics: metrics)
        self.windowChannel = channel
        self.composition = composition
        await composition.start()

        // ── snapshots → UI (MainActor) ────────────────────────────────────
        snapshotTask = Task { @MainActor [weak self, composition] in
            for await snap in composition.snapshots {
                self?.apply(snapshot: snap)
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
            [weak self, windowing, metrics = metricsRef, channel] in
            var current = initialResolved
            while !Task.isCancelled {
                await Self.publishMode(current: current, container: containerRef, on: self)
                do {
                    let stream = try await current.stream.start()
                    for try await sample in stream {
                        if Task.isCancelled { break }
                        let started = DispatchTime.now()
                        do {
                            if let window = try await windowing.ingest(sample) {
                                metrics.recordWindowing(durationMicros: elapsedMicros(since: started))
                                _ = channel.send(window)
                            } else {
                                metrics.recordWindowing(durationMicros: elapsedMicros(since: started))
                            }
                        } catch let bci as BCIError {
                            metrics.recordError(bci)
                            await MainActor.run { self?.lastError = bci.description }
                        }
                    }
                    // Clean completion (not an error). Exit.
                    break
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
                BCILog.pipeline.notice("Stream failure — falling back to synthetic")
                current = EEGStreamFactory.makeSynthetic()
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
        streamTask?.cancel();   streamTask = nil
        classifyTask?.cancel(); classifyTask = nil
        carouselTask?.cancel(); carouselTask = nil
        metricsTask?.cancel();  metricsTask = nil
        snapshotTask?.cancel(); snapshotTask = nil

        // Finish channels so any straggling iterators terminate cleanly.
        windowChannel?.finish()
        windowChannel = nil
        if let c = composition { await c.finish() }
        composition = nil

        isRunning = false
    }

    public func resetComposition(seed: String = "") async {
        await composition?.reset(to: seed)
    }

    // MARK: - Helpers

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
