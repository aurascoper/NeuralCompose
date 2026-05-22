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
///   • Maintain a ring of the last `historySize` predictions.
///   • For each candidate class, compute count + **average confidence** over
///     all predictions in the ring for that class.
///   • An intent is *active* iff its count ≥ activation bar AND its
///     averaged confidence ≥ `minConfidence`. A select requires a higher
///     activation count than an advance.
///   • Advance requires a *single* class to cross `activationCount` —
///     alternating noisy classes (jaw → blink → jaw → blink) do not fire.
///   • After firing `selectActive`, enter a refractory period during which
///     only `idle` can be emitted.
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

        // Tally count + summed confidence per class across the whole ring.
        // (No per-window threshold filter — the bar is on the *averaged*
        // confidence across the matching windows, which is what the docs say.)
        var totals: [IntentClass: (count: Int, sumConfidence: Float)] = [:]
        for p in history {
            var entry = totals[p.intent] ?? (0, 0)
            entry.count += 1
            entry.sumConfidence += p.confidence
            totals[p.intent] = entry
        }

        func meetsBar(_ entry: (count: Int, sumConfidence: Float), threshold: Int) -> Bool {
            guard entry.count >= threshold else { return false }
            let avg = entry.sumConfidence / Float(entry.count)
            return avg >= config.minConfidence
        }

        // Prefer .select if it crosses its higher bar.
        if let s = totals[.select], meetsBar(s, threshold: config.selectActivationCount) {
            refractoryRemaining = config.refractoryWindows
            return .selectActive
        }

        // Advance: a *single* non-rest, non-select class crosses
        // activationCount with sufficient averaged confidence. We do not sum
        // counts across classes — alternating noise must not fire.
        let advanceCandidates: [IntentClass] = [.jawClench, .singleBlink, .doubleBlink]
        for c in advanceCandidates {
            if let entry = totals[c], meetsBar(entry, threshold: config.activationCount) {
                return .advance
            }
        }
        return .idle
    }

    public func reset() {
        history.removeAll(keepingCapacity: true)
        refractoryRemaining = 0
    }
}
