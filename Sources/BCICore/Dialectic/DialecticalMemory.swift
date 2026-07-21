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
    private var heardEmbeddings: [Embedding] = []
    private var replyEmbeddings: [Embedding] = []
    private let historyWindow: Int
    private let tensionCeiling: Float

    /// Consecutive turns whose tension stayed at/below `tensionCeiling` — how
    /// long the dialogue has been converging.
    public private(set) var lowTensionStreak: Int = 0

    /// Texts the loop has recently *voiced* (spoken or synthesized). Synthesis
    /// must not resurface one of these verbatim: without this, an eager-synthesis
    /// profile (e.g. Focused) collapses to re-speaking the same central node
    /// every turn while the fresh candidates it just generated are discarded.
    /// Bounded to `historyWindow`.
    private var recentlyVoiced: [String] = []

    public init(historyWindow: Int = 16, graphCapacity: Int = 128,
                edgeThreshold: Float = 0.6, tensionCeiling: Float = 0.35) {
        self.historyWindow = max(1, historyWindow)
        self.tensionCeiling = tensionCeiling
        self.graph = SemanticGraph(capacity: graphCapacity, edgeThreshold: edgeThreshold)
    }

    // MARK: - Derived context

    /// L2-normalized mean of recent *heard* utterances — the human's trajectory.
    public var historyCentroid: Embedding? { DialecticalDynamics.centroid(of: heardEmbeddings) }
    /// L2-normalized mean of recent *replies* — the machine's trajectory.
    public var replyCentroid: Embedding? { DialecticalDynamics.centroid(of: replyEmbeddings) }

    /// How much the recent replies spread apart — a wandering, un-focused
    /// dialogue scores high. `[0, 1]`. (Consumed by the field at milestone 5.)
    public var entropy: Float { DialecticalDynamics.tension(among: replyEmbeddings) }

    /// How fast the machine's semantic position is moving — mean dissimilarity
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

    /// Records a voiced output so `synthesisCandidate` won't resurface it
    /// verbatim on a later turn. Call whenever a turn actually speaks (spoke or
    /// synthesized).
    public mutating func recordVoiced(_ text: String) {
        recentlyVoiced.append(text)
        if recentlyVoiced.count > historyWindow { recentlyVoiced.removeFirst() }
    }

    // MARK: - Synthesis (emergent third idea)

    /// Looks for a prior idea that bridges the two current poles — one that is
    /// far from each yet sits near their midpoint (`synthesisScore`). Returns it
    /// as a `.synthesized` candidate when it clears the bar: the gentle
    /// (`synthesisLowBar`) bar once the dialogue has been converging for
    /// `synthesisSustainK` turns, the strict (`synthesisHighBar`) bar otherwise.
    /// `nil` means "no synthesis this turn — let the poles keep competing."
    public func synthesisCandidate(thesis: Embedding, antithesis: Embedding,
                                   tuning: DialecticalDynamics.Tuning) -> DialecticalCandidate? {
        guard let query = DialecticalDynamics.centroid(of: [thesis, antithesis]) else { return nil }
        let bar = lowTensionStreak >= tuning.synthesisSustainK
            ? tuning.synthesisLowBar : tuning.synthesisHighBar

        let best = graph.nearestPriorNodes(to: query, limit: 10)
            // A synthesis reconciles the poles from a prior *reply* (something the
            // dialogue itself said) — never the user's own heard input, which
            // reads as parroting their words back. `nearestPriorNodes` stays
            // kind-agnostic (it's the general recurrence primitive); the .reply
            // restriction lives here, where synthesis is chosen.
            .filter { $0.kind == .reply }
            // Nor resurface something just voiced — the verbatim repetition an
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
