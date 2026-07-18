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
        /// Monotonically increasing count of genuine commit events (EEG
        /// `.commitActive`, `appendExternalText`, `applyRefinement` — never
        /// `reset()`). `lastCommittedWord` alone can't distinguish "no new
        /// commit happened" from "the user genuinely committed the same
        /// word twice in a row" — this sequence number can, and is the
        /// signal callers should actually compare, not the word text.
        public let commitSequence: UInt64

        public init(
            composedText: String,
            candidates: [PredictedWord],
            highlightIndex: Int,
            isPredicting: Bool,
            lastCommittedWord: String?,
            commitSequence: UInt64 = 0
        ) {
            self.composedText = composedText
            self.candidates = candidates
            self.highlightIndex = highlightIndex
            self.isPredicting = isPredicting
            self.lastCommittedWord = lastCommittedWord
            self.commitSequence = commitSequence
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

    /// Live, mutable override of `config`'s generation parameters — set via
    /// `updateGenerationAdaptation(_:)`. Kept separate from `config` (which
    /// stays construction-time-fixed) so the deterministic rule table
    /// driving this can change per EEG window without touching `Config`'s
    /// role as init-time defaults/seed context.
    private var adaptation: GenerationAdaptation

    private var composed: String
    private var candidates: [PredictedWord] = []
    private var highlightIndex: Int = 0
    private var isPredicting: Bool = false
    private var lastCommittedWord: String?
    private var commitSequence: UInt64 = 0

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
        self.adaptation = GenerationAdaptation(maxCandidates: config.maxCandidates, temperature: config.temperature)
        self.composed = config.seedContext
        self.snapshotChannel = BoundedAsyncChannel<Snapshot>(capacity: 16, overflow: .dropOldest)
    }

    public func start() async {
        await requestPredictions()
    }

    /// Applies a new deterministic generation adaptation (see
    /// `GenerationAdaptation`) — takes effect on the next
    /// `requestPredictions()` call, not retroactively.
    public func updateGenerationAdaptation(_ adaptation: GenerationAdaptation) async {
        self.adaptation = adaptation
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

    /// Merges a fully-transcribed utterance (or any other non-EEG text) into
    /// the same `composed` buffer EEG commits populate. Bypasses
    /// `stateMachine.step(_:)` entirely — this is a second, independent
    /// input modality into the buffer, not an EEG-sourced commit, so it must
    /// not perturb the FSM's phase/highlight state. Appends the whole
    /// string atomically (no notion of "in-progress" partial text).
    public func appendExternalText(_ text: String, source: CompositionSource) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        composed = appendToken(composed, trimmed)
        lastCommittedWord = trimmed.split(separator: " ").last.map(String.init) ?? trimmed
        commitSequence += 1
        metrics.recordExternalText(source: source, wordCount: trimmed.split(separator: " ").count)
        await requestPredictions()
        publishSnapshot()
    }

    /// Replaces `composed` outright with `text` — unlike `appendExternalText`,
    /// which appends, a dialectic synthesis is a full rewrite of the
    /// sentence, not a continuation. Preserves the FSM's current phase
    /// (unlike `reset(to:)`, which resets it) since accepting a refinement
    /// isn't the start of a new utterance.
    public func applyRefinement(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        composed = trimmed
        lastCommittedWord = trimmed.split(separator: " ").last.map(String.init)
        commitSequence += 1
        metrics.recordExternalText(source: .automation, wordCount: trimmed.split(separator: " ").count)
        await requestPredictions()
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
            commitSequence += 1
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
            // `promptContext` is what the predictor sees; `composed` (what's
            // displayed and what appendToken/appendExternalText operate on)
            // is never touched by the style instruction.
            let promptContext = adaptation.styleInstruction.isEmpty
                ? composed
                : "\(adaptation.styleInstruction)\n\(composed)"
            let words = try await predictor.predictNextWords(
                context: promptContext,
                maxCandidates: adaptation.maxCandidates,
                temperature: adaptation.temperature,
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
            lastCommittedWord: lastCommittedWord,
            commitSequence: commitSequence
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
