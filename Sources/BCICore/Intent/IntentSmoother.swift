import Foundation

/// Smooths raw per-window `IntentPrediction`s into a debounced `SmoothedIntent`.
///
/// Why:
///   • Per-window classifier output is noisy. The user is not going to clench
///     for exactly one window then stop.
///   • We want hysteresis between "advance" and "selectActive" so a single
///     spurious reading doesn't trigger a token commit.
///
/// Selection is **dwell-based**, not a distinct trained gesture: sustained
/// `.rest` classification while a candidate is highlighted is what commits
/// it. Replaces an earlier design where a separate `select` `IntentClass`
/// drove commit — found live (2026-07-17) to have no defined physical
/// gesture behind it, unlike jawClench/singleBlink/doubleBlink, which
/// already fully cover advancing. `.select` predictions are still accepted
/// from the classifier (the trained model still has 5 output classes) but
/// are deliberately treated as ordinary non-advancing signal — they don't
/// drive the FSM at all anymore.
///
/// Strategy:
///   • Maintain a ring of the last `historySize` predictions.
///   • For each candidate class, compute count + **average confidence** over
///     all predictions in the ring for that class.
///   • An intent is *active* iff its count ≥ activation bar AND its
///     averaged confidence ≥ `minConfidence`. Dwell-select requires a higher
///     activation count than an advance — deliberately staying still for
///     longer than a single incidental pause between gestures.
///   • Advance requires a *single* class to cross `activationCount` —
///     alternating noisy classes (jaw → blink → jaw → blink) do not fire.
///   • After firing `selectActive`, enter a refractory period during which
///     only `idle` can be emitted.
public actor IntentSmoother {

    public struct Config: Sendable {
        public var historySize: Int
        public var activationCount: Int
        /// Consecutive-rest bar for dwell-select — deliberately higher than
        /// `activationCount` so an ordinary pause between advance gestures
        /// doesn't read as "commit this word." Tune against real
        /// false-positive/false-negative rates, not by guessing; starts at
        /// the same value as the gesture-based bar it replaced rather than
        /// assuming dwelling is easier to hold and shortening it blind.
        public var dwellActivationCount: Int
        public var minConfidence: Float
        public var refractoryWindows: Int

        public init(
            historySize: Int = 5,
            activationCount: Int = 3,
            dwellActivationCount: Int = 4,
            minConfidence: Float = 0.55,
            refractoryWindows: Int = 6
        ) {
            self.historySize = historySize
            self.activationCount = activationCount
            self.dwellActivationCount = dwellActivationCount
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
        // Refractory predictions are deliberately NOT appended to `history`.
        // They used to be appended unconditionally before this check, which
        // let ambient `.rest` accumulated purely during the cooldown (the
        // user isn't gesturing right after a commit) refill the ring enough
        // to immediately re-cross the dwell bar the instant refractory
        // ended — an unintended auto-commit with no deliberate dwell action.
        // Refractory now means "not observed" for smoothing purposes, not
        // just "not acted on."
        if refractoryRemaining > 0 {
            refractoryRemaining -= 1
            return .idle
        }

        history.append(prediction)
        if history.count > config.historySize { history.removeFirst() }

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

        // Dwell-select: sustained .rest crossing its higher bar. Checked
        // before advance so a candidate the user has settled on (gone still)
        // commits rather than getting reinterpreted as noise.
        if let r = totals[.rest], meetsBar(r, threshold: config.dwellActivationCount) {
            // Clear the ring so refractory starts from a clean slate — combined
            // with not appending during refractory (above), the next
            // dwell-select requires `dwellActivationCount` genuinely-new
            // post-refractory `.rest` windows, not stale/ambient ones.
            history.removeAll(keepingCapacity: true)
            refractoryRemaining = config.refractoryWindows
            return .selectActive
        }

        // Advance: a *single* non-rest class crosses activationCount with
        // sufficient averaged confidence. We do not sum counts across
        // classes — alternating noise must not fire. `.select` is
        // deliberately excluded here too, not just from the dwell check
        // above — see the type doc comment.
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
