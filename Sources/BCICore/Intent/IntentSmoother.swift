import Foundation

/// Smooths raw per-window `IntentPrediction`s into a debounced `SmoothedIntent`.
///
/// Why:
///   • Per-window classifier output is noisy. The user is not going to clench
///     for exactly one window then stop.
///   • We want hysteresis between "advance" and "selectActive" so a single
///     spurious select prediction doesn't trigger a token commit.
///
/// Strategy:
///   • Maintain a small ring of the last N predictions.
///   • An intent is *active* iff ≥ `activationCount` of the last N predictions
///     match it AND the average confidence over those windows ≥ `minConfidence`.
///   • A select requires a *higher* activation count than an advance.
///   • After firing `selectActive`, enter a refractory period during which
///     only `idle` can be emitted — prevents double-fires.
public actor IntentSmoother {

    public struct Config: Sendable {
        public var historySize: Int
        public var activationCount: Int
        public var selectActivationCount: Int
        public var minConfidence: Float
        public var refractoryWindows: Int

        public init(
            historySize: Int = 5,
            activationCount: Int = 3,
            selectActivationCount: Int = 4,
            minConfidence: Float = 0.55,
            refractoryWindows: Int = 6
        ) {
            self.historySize = historySize
            self.activationCount = activationCount
            self.selectActivationCount = selectActivationCount
            self.minConfidence = minConfidence
            self.refractoryWindows = refractoryWindows
        }
    }

    private let config: Config
    private var history: [IntentPrediction] = []
    private var refractoryRemaining: Int = 0

    public init(config: Config = .init()) {
        self.config = config
        self.history.reserveCapacity(config.historySize + 1)
    }

    public func ingest(_ prediction: IntentPrediction) -> SmoothedIntent {
        history.append(prediction)
        if history.count > config.historySize { history.removeFirst() }

        if refractoryRemaining > 0 {
            refractoryRemaining -= 1
            return .idle
        }

        // Count per-class hits with confidence ≥ threshold.
        var counts: [IntentClass: (count: Int, sumConfidence: Float)] = [:]
        for p in history where p.confidence >= config.minConfidence {
            counts[p.intent, default: (0, 0)].count += 1
            counts[p.intent, default: (0, 0)].sumConfidence += p.confidence
        }

        // Prefer .select if it crosses its higher bar.
        if let s = counts[.select],
           s.count >= config.selectActivationCount {
            refractoryRemaining = config.refractoryWindows
            return .selectActive
        }

        // Advance: any non-rest, non-select intent reaches its activation bar.
        let advanceCandidates: [IntentClass] = [.jawClench, .singleBlink, .doubleBlink]
        let advanceTotal = advanceCandidates.reduce(0) { acc, c in
            acc + (counts[c]?.count ?? 0)
        }
        if advanceTotal >= config.activationCount {
            return .advance
        }
        return .idle
    }

    public func reset() {
        history.removeAll(keepingCapacity: true)
        refractoryRemaining = 0
    }
}
