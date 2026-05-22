import Foundation

/// Composes the sentence the user is building, holds the live candidate
/// carousel, and exposes a stream of UI state snapshots.
///
/// Stays inside `BCICore` so unit tests can drive it with `MockIntentClassifier`
/// + `StubNextWordPredictor` without dragging in MLX, BrainFlow, or SwiftUI.
///
/// Threading model:
///   • This is an `actor` — calls are serialized on its executor.
///   • The pipeline (windowing → classifier → smoother) calls `applyIntent`.
///   • The UI's 1.5 s carousel timer calls `tick()`.
///   • Both calls produce a new `Snapshot` published on `snapshots`.
public actor TextCompositionController {

    public struct Snapshot: Sendable, Hashable {
        public let composedText: String
        public let candidates: [PredictedWord]
        public let highlightIndex: Int
        public let isPredicting: Bool
        public let lastCommittedWord: String?

        public init(
            composedText: String,
            candidates: [PredictedWord],
            highlightIndex: Int,
            isPredicting: Bool,
            lastCommittedWord: String?
        ) {
            self.composedText = composedText
            self.candidates = candidates
            self.highlightIndex = highlightIndex
            self.isPredicting = isPredicting
            self.lastCommittedWord = lastCommittedWord
        }

        public var activeCandidate: PredictedWord? {
            guard candidates.indices.contains(highlightIndex) else { return nil }
            return candidates[highlightIndex]
        }
    }

    public struct Config: Sendable {
        public var maxCandidates: Int
        public var temperature: Double
        public var seedContext: String
        public init(maxCandidates: Int = 3, temperature: Double = 0.7, seedContext: String = "") {
            self.maxCandidates = maxCandidates
            self.temperature = temperature
            self.seedContext = seedContext
        }
    }

    private let predictor: any NextWordPredicting
    private let metrics: any MetricsRecording
    private let config: Config
    private var stateMachine = IntentStateMachine()

    private var composed: String
    private var candidates: [PredictedWord] = []
    private var highlightIndex: Int = 0
    private var isPredicting: Bool = false
    private var lastCommittedWord: String?

    private var currentCancellation = UUID()

    private let snapshotChannel: BoundedAsyncChannel<Snapshot>
    public nonisolated var snapshots: AsyncStream<Snapshot> { snapshotChannel.stream }

    public init(
        predictor: any NextWordPredicting,
        metrics: any MetricsRecording = NullMetricsRecorder(),
        config: Config = .init()
    ) {
        self.predictor = predictor
        self.metrics = metrics
        self.config = config
        self.composed = config.seedContext
        self.snapshotChannel = BoundedAsyncChannel<Snapshot>(capacity: 16, overflow: .dropOldest)
    }

    public func start() async {
        await requestPredictions()
    }

    public func tick() async {
        let action = stateMachine.step(.timerTick)
        await handleAction(action)
        metrics.recordCarouselTick()
        publishSnapshot()
    }

    public func applyIntent(_ intent: SmoothedIntent) async {
        metrics.recordIntent(intent)
        let action = stateMachine.step(.smoothed(intent))
        await handleAction(action)
        publishSnapshot()
    }

    public func reset(to seed: String = "") async {
        currentCancellation = UUID()
        _ = stateMachine.step(.reset)
        composed = seed
        candidates = []
        highlightIndex = 0
        isPredicting = false
        lastCommittedWord = nil
        publishSnapshot()
        await requestPredictions()
    }

    public func finish() {
        snapshotChannel.finish()
    }

    // MARK: - Internal

    private func handleAction(_ action: IntentStateMachine.Action) async {
        switch action {
        case .noop:
            return
        case .advanceHighlight:
            guard !candidates.isEmpty else { return }
            highlightIndex = (highlightIndex + 1) % candidates.count
        case .commitActive:
            guard let active = currentActive else { return }
            composed = appendToken(composed, active.text)
            lastCommittedWord = active.text
            metrics.recordSelection(committedToken: active.text)
            await requestPredictions()
        }
    }

    private var currentActive: PredictedWord? {
        guard candidates.indices.contains(highlightIndex) else { return nil }
        return candidates[highlightIndex]
    }

    private func requestPredictions() async {
        let id = UUID()
        currentCancellation = id
        isPredicting = true
        _ = stateMachine.step(.predictionsRequested)
        publishSnapshot()

        let started = DispatchTime.now()
        do {
            let words = try await predictor.predictNextWords(
                context: composed,
                maxCandidates: config.maxCandidates,
                temperature: config.temperature,
                cancellationID: id
            )
            // Bail if a newer commit happened while this call was outstanding.
            guard id == currentCancellation else { return }
            candidates = words.isEmpty ? [PredictedWord(text: " the", probability: 0.0)] : words
            highlightIndex = 0
            isPredicting = false
            _ = stateMachine.step(.predictionsReady)
            metrics.recordPrediction(
                durationMicros: elapsedMicros(since: started),
                modelIdentifier: predictor.modelIdentifier
            )
            publishSnapshot()
        } catch is CancellationError {
            return
        } catch {
            // Surface degraded state — keep showing whatever we had.
            isPredicting = false
            if let bci = error as? BCIError { metrics.recordError(bci) }
            _ = stateMachine.step(.predictionsReady)
            publishSnapshot()
        }
    }

    private func publishSnapshot() {
        let snap = Snapshot(
            composedText: composed,
            candidates: candidates,
            highlightIndex: highlightIndex,
            isPredicting: isPredicting,
            lastCommittedWord: lastCommittedWord
        )
        _ = snapshotChannel.send(snap)
    }

    private func appendToken(_ existing: String, _ token: String) -> String {
        // If the token already begins with whitespace, splice as-is.
        // Otherwise, insert a single space when needed.
        if existing.isEmpty { return token.drop(while: { $0 == " " }).description }
        if token.first == " " { return existing + token }
        if existing.last == " " { return existing + token }
        return existing + " " + token
    }

    private func elapsedMicros(since start: DispatchTime) -> UInt64 {
        let end = DispatchTime.now()
        let ns = end.uptimeNanoseconds &- start.uptimeNanoseconds
        return ns / 1_000
    }
}
