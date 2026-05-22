import Foundation
import SwiftUI
import Combine
import BCICore
import BCIEEG
import BCIClassifier
import BCILLM

/// Owns the live pipeline: EEG stream → windowing → classifier → smoother →
/// composition → carousel → UI. Lives on `@MainActor` so SwiftUI observation
/// is straightforward; the heavy work happens in detached tasks and `actor`s.
///
/// Cancellation is hierarchical: stopping the view model cancels the EEG
/// task, which cascades into the classifier, smoother, and composition tasks.
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
    @Published public var computeMode: ClassifierComputeMode {
        didSet {
            // Compute-mode changes are reflected in metrics; an actual
            // re-load would happen via `applyComputeModeChange()` if the
            // user opts in. We intentionally do not auto-reload to avoid
            // disrupting the live pipeline.
        }
    }
    @Published public var isRunning: Bool = false

    // ── Wiring ────────────────────────────────────────────────────────────
    public let container: AppContainer
    private let metrics: MetricsCollector
    private let windowing: EEGWindowing
    private let smoother: IntentSmoother
    private let composition: TextCompositionController
    private let classifier: any IntentClassifying
    private let predictor: any NextWordPredicting

    private var streamTask: Task<Void, Never>?
    private var classifyTask: Task<Void, Never>?
    private var snapshotTask: Task<Void, Never>?
    private var carouselTask: Task<Void, Never>?
    private var metricsTask: Task<Void, Never>?

    // Internal channel: windows from the EEG ingest pipeline.
    private let windowChannel = BoundedAsyncChannel<EEGWindow>(capacity: 8, overflow: .dropOldest)

    public init(container: AppContainer) {
        self.container = container
        self.metrics = container.metrics
        self.classifier = container.classifierResolved.classifier
        self.predictor = container.predictorResolved.predictor
        self.pipelineMode = container.pipelineMode
        self.computeMode = container.classifierResolved.computeMode
        self.windowing = EEGWindowing(config: container.windowingConfig)
        self.smoother = IntentSmoother(config: container.smootherConfig)
        self.composition = TextCompositionController(
            predictor: container.predictorResolved.predictor,
            metrics: container.metrics
        )
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

        await composition.start()

        // Snapshots from composition → UI.
        snapshotTask = Task { [weak self] in
            guard let self = self else { return }
            for await snap in self.composition.snapshots {
                await MainActor.run { self.apply(snapshot: snap) }
            }
        }

        // 1.5 s carousel tick.
        carouselTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                guard let self = self else { return }
                await self.composition.tick()
            }
        }

        // Metrics polling — 4 Hz.
        metricsTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard let self = self else { return }
                let snap = self.metrics.snapshot()
                await MainActor.run { self.metricsSnapshot = snap }
            }
        }

        // EEG stream → windowing → channel.
        streamTask = Task { [weak self] in
            guard let self = self else { return }
            do {
                let asyncStream = try await self.container.streamResolved.stream.start()
                for try await sample in asyncStream {
                    let start = DispatchTime.now()
                    do {
                        if let window = try await self.windowing.ingest(sample) {
                            self.metrics.recordWindowing(durationMicros: elapsedMicros(since: start))
                            _ = self.windowChannel.send(window)
                        } else {
                            self.metrics.recordWindowing(durationMicros: elapsedMicros(since: start))
                        }
                    } catch let bci as BCIError {
                        self.metrics.recordError(bci)
                        await MainActor.run { self.lastError = bci.description }
                    }
                }
            } catch let bci as BCIError {
                self.metrics.recordError(bci)
                await MainActor.run { self.lastError = bci.description }
            } catch {
                let bci = BCIError.streamFailed(reason: error.localizedDescription)
                self.metrics.recordError(bci)
                await MainActor.run { self.lastError = bci.description }
            }
            // If the stream ends and we're still running, fall through to
            // synthetic. The factory already chose the right thing at start;
            // if a real device disconnects, we don't auto-reconnect here.
        }

        // Window channel → classifier → smoother → composition.
        classifyTask = Task { [weak self] in
            guard let self = self else { return }
            for await window in self.windowChannel.stream {
                let cStart = DispatchTime.now()
                let prediction: IntentPrediction
                do {
                    prediction = try await self.classifier.classify(window: window)
                    self.metrics.recordClassification(
                        durationMicros: elapsedMicros(since: cStart),
                        computeMode: self.classifier.computeMode
                    )
                } catch let bci as BCIError {
                    self.metrics.recordError(bci)
                    await MainActor.run { self.lastError = bci.description }
                    continue
                } catch {
                    let bci = BCIError.classifierInferenceFailed(reason: error.localizedDescription)
                    self.metrics.recordError(bci)
                    await MainActor.run { self.lastError = bci.description }
                    continue
                }
                let smoothed = await self.smoother.ingest(prediction)
                await self.composition.applyIntent(smoothed)
            }
        }
    }

    public func stop() async {
        streamTask?.cancel(); streamTask = nil
        classifyTask?.cancel(); classifyTask = nil
        carouselTask?.cancel(); carouselTask = nil
        metricsTask?.cancel(); metricsTask = nil
        snapshotTask?.cancel(); snapshotTask = nil
        await container.streamResolved.stream.stop()
        await composition.finish()
        windowChannel.finish()
        isRunning = false
    }

    public func resetComposition(seed: String = "") async {
        await composition.reset(to: seed)
    }

    // MARK: - Helpers

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
