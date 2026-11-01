import Foundation

/// The memory the dialectic lives in. Wraps the temporal reply/heard rings that
/// feed the competition's centroids **and** the `SemanticGraph` that lets old
/// ideas recur. It also derives the slow-clock quantities the `DialecticalField`
/// will consume at milestone 5 (`entropy`, `drift`) and tracks the low-tension
/// streak that gates synthesis.
///
/// Pure value type mutated in place by the owning actor; no I/O.
public struct DialecticalMemory: Sendable {

    public private(set) var graph: SemanticGraph
    public private(set) var heardEmbeddings: [Embedding] = []
    public private(set) var replyEmbeddings: [Embedding] = []
    private let historyWindow: Int
    private let graphCapacity: Int
    private let tensionCeiling: Float

    /// Consecutive turns whose tension stayed at/below `tensionCeiling` - how
    /// long the dialogue has been converging.
    public private(set) var lowTensionStreak: Int = 0

    /// Consecutive turns whose spoken reply collapsed onto the rolling reply
    /// centroid (`selfSimilarity >= collapseThreshold`, default `0.85`).
    public private(set) var reflexiveCollapseStreak: Int = 0

    /// Total number of conditional autoforget events triggered in this memory instance.
    public private(set) var autoforgetCount: Int = 0

    /// Texts the loop has recently *voiced* (spoken or synthesized). Synthesis
    /// must not resurface one of these verbatim: without this, an eager-synthesis
    /// profile (e.g. Focused) collapses to re-speaking the same central node
    /// every turn while the fresh candidates it just generated are discarded.
    /// Bounded to `graphCapacity` so no voiced reply still resident in `graph`
    /// is ever replayed verbatim once `turnIndex` exceeds `historyWindow`.
    private var recentlyVoiced: [String] = []

    public init(historyWindow: Int = 16, graphCapacity: Int = 128,
                edgeThreshold: Float = 0.6, tensionCeiling: Float = 0.35) {
        self.historyWindow = max(1, historyWindow)
        self.graphCapacity = max(self.historyWindow, graphCapacity)
        self.tensionCeiling = tensionCeiling
        self.graph = SemanticGraph(capacity: graphCapacity, edgeThreshold: edgeThreshold)
    }

    // MARK: - Derived context

    /// L2-normalized mean of recent *heard* utterances - the human's trajectory.
    public var historyCentroid: Embedding? { DialecticalDynamics.centroid(of: heardEmbeddings) }
    /// L2-normalized mean of recent *replies* - the machine's trajectory.
    public var replyCentroid: Embedding? { DialecticalDynamics.centroid(of: replyEmbeddings) }

    /// How much the recent replies spread apart - a wandering, un-focused
    /// dialogue scores high. `[0, 1]`. (Consumed by the field at milestone 5.)
    public var entropy: Float { DialecticalDynamics.tension(among: replyEmbeddings) }

    /// How fast the machine's semantic position is moving - mean dissimilarity
    /// between consecutive replies. `[0, 1]`. (Consumed by the field at 5.)
    public var drift: Float {
        guard replyEmbeddings.count >= 2 else { return 0 }
        var acc: Float = 0
        for i in 1..<replyEmbeddings.count {
            acc += 1 - DialecticalDynamics.normalized(
                replyEmbeddings[i].cosineSimilarity(to: replyEmbeddings[i - 1]))
        }
        return acc / Float(replyEmbeddings.count - 1)
    }

    // MARK: - Recording

    public mutating func recordHeard(text: String, embedding: Embedding, turnIndex: Int) {
        heardEmbeddings.append(embedding)
        if heardEmbeddings.count > historyWindow { heardEmbeddings.removeFirst() }
        graph.insert(text: text, embedding: embedding, turnIndex: turnIndex, kind: .heard)
    }

    public mutating func recordReply(text: String, embedding: Embedding, turnIndex: Int) {
        replyEmbeddings.append(embedding)
        if replyEmbeddings.count > historyWindow { replyEmbeddings.removeFirst() }
        graph.insert(text: text, embedding: embedding, turnIndex: turnIndex, kind: .reply)
    }

    /// Updates the convergence streak from this turn's tension. Call once per
    /// turn, *after* using `lowTensionStreak` for the synthesis decision.
    public mutating func observe(tension: Float) {
        lowTensionStreak = tension <= tensionCeiling ? lowTensionStreak + 1 : 0
    }

    /// Resets the convergence streak once a synthesis event has resolved the
    /// accumulated low-tension run, preventing back-to-back synthesis replays.
    public mutating func resetLowTensionStreak() {
        lowTensionStreak = 0
    }

    /// Records a voiced output so `synthesisCandidate` won't resurface it
    /// verbatim on a later turn. Call whenever a turn actually speaks (spoke or
    /// synthesized).
    public mutating func recordVoiced(_ text: String) {
        recentlyVoiced.append(text)
        if recentlyVoiced.count > graphCapacity { recentlyVoiced.removeFirst() }
    }

    // MARK: - Conditional Autoforgetting & Autobank Gate (when/iff needed)

    /// Conditional autoforgetting ("when/iff needed"):
    /// Tracks consecutive reflexive-collapse turns (`selfSimilarity >= collapseThreshold`,
    /// default `0.85` matching `session-seed.py`). Iff `forceReset` is true OR
    /// `reflexiveCollapseStreak >= sustainK` while `replyEmbeddings.count > minRetained`,
    /// prunes the oldest half of `heardEmbeddings` and `replyEmbeddings` (retaining at
    /// least `minRetained` recent embeddings so the reply centroid never vanishes mid-run)
    /// and resets `reflexiveCollapseStreak`. The long-horizon `SemanticGraph` and
    /// `recentlyVoiced` deduplication ring are preserved so synthesis can still bridge
    /// without verbatim repetition.
    ///
    /// - Returns: `true` iff an autoforget prune was executed on this call.
    @discardableResult
    public mutating func autoforgetIfNeeded(
        selfSimilarity: Float?,
        collapseThreshold: Float = 0.85,
        sustainK: Int = 2,
        minRetained: Int = 2,
        forceReset: Bool = false
    ) -> Bool {
        if let sim = selfSimilarity, sim >= collapseThreshold {
            reflexiveCollapseStreak += 1
        } else {
            reflexiveCollapseStreak = 0
        }

        let keepFloor = max(1, minRetained)
        if forceReset {
            if heardEmbeddings.count > keepFloor {
                heardEmbeddings.removeFirst(heardEmbeddings.count - keepFloor)
            }
            if replyEmbeddings.count > keepFloor {
                replyEmbeddings.removeFirst(replyEmbeddings.count - keepFloor)
            }
            reflexiveCollapseStreak = 0
            lowTensionStreak = 0
            autoforgetCount += 1
            return true
        }

        guard reflexiveCollapseStreak >= max(1, sustainK),
              replyEmbeddings.count > keepFloor else {
            return false
        }

        let targetReplyKeep = max(keepFloor, replyEmbeddings.count / 2)
        if replyEmbeddings.count > targetReplyKeep {
            replyEmbeddings.removeFirst(replyEmbeddings.count - targetReplyKeep)
        }
        let targetHeardKeep = max(keepFloor, heardEmbeddings.count / 2)
        if heardEmbeddings.count > targetHeardKeep {
            heardEmbeddings.removeFirst(heardEmbeddings.count - targetHeardKeep)
        }
        reflexiveCollapseStreak = 0
        autoforgetCount += 1
        return true
    }

    /// Evaluates whether a completed dialectical turn warrants banking into persistent
    /// SQL memory / session-time autobank manifest when/iff needed, returning both the
    /// boolean decision and the canonical reason code matching `Scripts/memory-gate.py`.
    /// Rejects silent turns, single-token repetition stutters, short backchannels/hedges
    /// (`< 3` heard words or `< 5` combined heard+spoken substantive tokens), routine
    /// control/transit commands, and unmitigated reflexive-collapse turns (`> 0.92`).
    public static func evaluateAutobankWarrant(
        heard: String,
        spoken: String?,
        outcome: String,
        selfSimilarity: Float?,
        maxSelfSimilarity: Float = 0.92
    ) -> (eligible: Bool, reason: String) {
        let rolePrefix = outcome.split(separator: ":", maxSplits: 1).first.map(String.init) ?? ""
        guard rolePrefix == "spoke" || rolePrefix == "synthesized" else {
            return (false, "silent_turn")
        }
        guard let reply = spoken?.trimmingCharacters(in: .whitespacesAndNewlines),
              !reply.isEmpty else {
            return (false, "empty_spoken")
        }
        let cleanHeard = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = cleanHeard.lowercased().trimmingCharacters(in: .punctuationCharacters)
        let words = lowered.split(whereSeparator: { $0.isWhitespace })
            .map { $0.trimmingCharacters(in: .punctuationCharacters) }
            .filter { !$0.isEmpty }
        let spokenWords = reply.lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .map { $0.trimmingCharacters(in: .punctuationCharacters) }
            .filter { !$0.isEmpty }
        guard !words.isEmpty else {
            return (false, "short_backchannel_or_hedge")
        }
        // Reject routine control/transit phrases
        let transientPrefixes = [
            "turn off", "turn it off", "switch off", "forget that", "clear memory",
            "reset memory", "clear history", "reset history",
            "ok i should be good", "okay i should be good", "i'll be down in a second",
            "be down in a second", "be right back", "hold on a second"
        ]
        if transientPrefixes.contains(where: { lowered == $0 || lowered.hasPrefix($0 + " ") || lowered.contains($0) }) {
            return (false, "transient_control_or_transit")
        }
        // Reject single-word repetition stutters (e.g. "sex sex sex", "Sex, sex, sex.")
        if words.count >= 2 && Set(words).count == 1 {
            return (false, "single_token_stutter")
        }
        guard words.count >= 3, (words.count + spokenWords.count) >= 5 else {
            return (false, "short_backchannel_or_hedge")
        }
        if let sim = selfSimilarity, sim > maxSelfSimilarity {
            return (false, String(format: "reflexive_collapse_gt_%.2f", maxSelfSimilarity))
        }
        return (true, "warranted")
    }

    /// Evaluates whether a completed dialectical turn warrants banking into persistent
    /// SQL memory / session-time autobank manifest when/iff needed.
    public static func shouldAutobankTurn(
        heard: String,
        spoken: String?,
        outcome: String,
        selfSimilarity: Float?,
        maxSelfSimilarity: Float = 0.92
    ) -> Bool {
        evaluateAutobankWarrant(
            heard: heard,
            spoken: spoken,
            outcome: outcome,
            selfSimilarity: selfSimilarity,
            maxSelfSimilarity: maxSelfSimilarity
        ).eligible
    }

    // MARK: - Synthesis (emergent third idea)

    /// Looks for a prior idea that bridges the two current poles - one that is
    /// far from each yet sits near their midpoint (`synthesisScore`). Returns it
    /// as a `.synthesized` candidate when it clears the bar: the gentle
    /// (`synthesisLowBar`) bar once the dialogue has been converging for
    /// `synthesisSustainK` turns, the strict (`synthesisHighBar`) bar otherwise.
    /// `nil` means "no synthesis this turn - let the poles keep competing."
    public func synthesisCandidate(thesis: Embedding, antithesis: Embedding,
                                   tuning: DialecticalDynamics.Tuning) -> DialecticalCandidate? {
        guard let query = DialecticalDynamics.centroid(of: [thesis, antithesis]) else { return nil }
        let bar = lowTensionStreak >= tuning.synthesisSustainK
            ? tuning.synthesisLowBar : tuning.synthesisHighBar

        let best = graph.nearestPriorNodes(to: query, limit: 10)
            // A synthesis reconciles the poles from a prior *reply* (something the
            // dialogue itself said) - never the user's own heard input, which
            // reads as parroting their words back. `nearestPriorNodes` stays
            // kind-agnostic (it's the general recurrence primitive); the .reply
            // restriction lives here, where synthesis is chosen.
            .filter { $0.kind == .reply }
            // Nor resurface something just voiced - the verbatim repetition an
            // eager-synthesis profile otherwise produces.
            .filter { !recentlyVoiced.contains($0.text) }
            .map { node -> (SemanticGraph.Node, Float) in
                (node, DialecticalDynamics.synthesisScore(candidate: node.embedding,
                                                          thesis: thesis, antithesis: antithesis))
            }
            .max { $0.1 < $1.1 }

        guard let best, best.1 >= bar else { return nil }
        return DialecticalCandidate(text: best.0.text, embedding: best.0.embedding, roleID: "synthesis")
    }
}
