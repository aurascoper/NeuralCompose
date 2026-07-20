import Foundation

/// The pure math of one dialectical turn: score candidates on the three
/// semantic axes, measure the tension between them, and resolve the competition
/// into an outcome. No I/O, no MLX, no actor state — every function is a pure
/// mapping so the whole engine is exhaustively testable with fixed embeddings
/// and a fixed random draw.
///
/// Design notes worth keeping in view:
///  - **Selection is a single softmax sample, not a branch.** "Decisive" and
///    "near-equilibrium" are the *same* mechanism at different margins: with a
///    tension-sharpened temperature, a large potential gap makes the sample
///    near-deterministic, while a near-zero gap lets the injected perturbation
///    tip the basin (a bifurcation). We record `margin`/`decisiveGap` for
///    diagnostics but do not hard-fork on them.
///  - **Tension never scores a candidate.** As an additive term it is identical
///    for every candidate and cancels in the softmax ratio, so it instead
///    modulates the selection temperature `τ(T)`, the silence gate, and (in the
///    loop) the generator prompts and prosody spread.
public enum DialecticalDynamics {

    /// Small, well-commented knobs. These are the tunables the plan flags for
    /// hand-tuning; the field-driven weights arrive at milestone 5.
    public struct Tuning: Sendable {
        /// Base selection temperature at zero tension (softer competition).
        public var tauBase: Float
        /// How much rising tension sharpens the competition (lowers `τ`).
        public var tauTensionSlope: Float
        /// Floor so `τ` never reaches zero (which would trap argmax and kill
        /// the bifurcation entirely).
        public var tauMin: Float
        /// A turn is a stalemate when the top-two potential gap is below this.
        public var stalemateMargin: Float
        /// …and only *falls silent* on a stalemate when tension is at least
        /// this high. A low-tension near-tie is a genuine near-agreement, which
        /// should still speak — silence is reserved for unresolved opposition.
        public var highTension: Float
        /// Margin at/above which the turn is flagged `decisive` (diagnostic only).
        public var decisiveGap: Float
        /// The semantic-axis weights (fixed until the field takes over).
        public var weights: DialecticalWeights
        /// `synthesisScore` a resurfaced idea must clear to interrupt as an
        /// emergent third when the dialogue is *not* converging.
        public var synthesisHighBar: Float
        /// The gentler bar once tension has stayed low for `synthesisSustainK`
        /// turns — convergence invites a synthesis.
        public var synthesisLowBar: Float
        /// Consecutive low-tension turns after which the gentler bar applies.
        public var synthesisSustainK: Int
        /// Tension at/below which a turn counts as "converging" for the streak.
        public var synthesisTensionCeiling: Float
        /// Slow clock: fraction the weight field moves toward its target each
        /// turn. Small ⇒ the dialogue's semantic identity has inertia.
        public var fieldInertia: Float
        /// Fast clock: EMA smoothing on the `SpectralState` gloss (per window).
        public var glossEMAAlpha: Float
        /// Maximum weight shift the gloss/history can induce — how strong the
        /// "wind" is. Kept modest so EEG biases, never dictates.
        public var glossWind: Float

        public init(
            tauBase: Float = 0.5,
            tauTensionSlope: Float = 0.35,
            tauMin: Float = 0.12,
            stalemateMargin: Float = 0.05,
            highTension: Float = 0.6,
            decisiveGap: Float = 0.25,
            weights: DialecticalWeights = .balanced,
            synthesisHighBar: Float = 0.6,
            synthesisLowBar: Float = 0.45,
            synthesisSustainK: Int = 4,
            synthesisTensionCeiling: Float = 0.35,
            fieldInertia: Float = 0.12,
            glossEMAAlpha: Float = 0.6,
            glossWind: Float = 0.35
        ) {
            self.tauBase = tauBase
            self.tauTensionSlope = tauTensionSlope
            self.tauMin = tauMin
            self.stalemateMargin = stalemateMargin
            self.highTension = highTension
            self.decisiveGap = decisiveGap
            self.weights = weights
            self.synthesisHighBar = synthesisHighBar
            self.synthesisLowBar = synthesisLowBar
            self.synthesisSustainK = synthesisSustainK
            self.synthesisTensionCeiling = synthesisTensionCeiling
            self.fieldInertia = fieldInertia
            self.glossEMAAlpha = glossEMAAlpha
            self.glossWind = glossWind
        }

        public static let `default` = Tuning()
    }

    /// The resolved competition plus the intermediate quantities the loop needs
    /// to build a `DialecticalCompetition` record.
    public struct Result: Sendable, Equatable {
        public let outcome: DialecticalOutcome
        public let tension: Float
        public let margin: Float
        public let selectionTemperature: Float
        /// True when the potential gap alone would have decided the turn
        /// (margin ≥ `decisiveGap`) — the dynamics, not the perturbation, won.
        public let decisive: Bool
    }

    // MARK: - Scoring

    /// Maps a raw cosine similarity `[-1, 1]` onto `[0, 1]` so every axis and
    /// the tension share one non-negative scale (the `DialecticalWeights`
    /// contract assumes `[0, 1]` inputs).
    @inlinable
    public static func normalized(_ cosine: Float) -> Float { (cosine + 1) / 2 }

    /// Scores one candidate against the turn context. Missing centroids (early
    /// turns, before any history) score a neutral `0.5` rather than biasing the
    /// competition toward either pole.
    public static func energy(
        candidate: Embedding,
        heard: Embedding,
        historyCentroid: Embedding?,
        replyCentroid: Embedding?
    ) -> DialecticalEnergy {
        let coherence = normalized(candidate.cosineSimilarity(to: heard))
        let resonance = historyCentroid.map { normalized(candidate.cosineSimilarity(to: $0)) } ?? 0.5
        // novelty = distance from what we've said; 1 − similarity, on the [0,1] scale.
        let novelty = replyCentroid.map { 1 - normalized(candidate.cosineSimilarity(to: $0)) } ?? 0.5
        return DialecticalEnergy(coherence: coherence, resonance: resonance, novelty: novelty)
    }

    /// Mean pairwise dissimilarity among the candidate embeddings, on `[0, 1]`.
    /// Zero or one candidate ⇒ no tension.
    public static func tension(among embeddings: [Embedding]) -> Float {
        guard embeddings.count >= 2 else { return 0 }
        var acc: Float = 0
        var pairs = 0
        for i in 0..<embeddings.count {
            for j in (i + 1)..<embeddings.count {
                acc += 1 - normalized(embeddings[i].cosineSimilarity(to: embeddings[j]))
                pairs += 1
            }
        }
        return pairs == 0 ? 0 : acc / Float(pairs)
    }

    /// `τ(T)`: higher tension → lower temperature → a sharper competition (which
    /// is *also* more volatile near equilibrium, since a tiny margin under a low
    /// `τ` flips on the smallest perturbation).
    public static func selectionTemperature(tension: Float, tuning: Tuning) -> Float {
        max(tuning.tauMin, tuning.tauBase - tuning.tauTensionSlope * tension)
    }

    // MARK: - Selection

    /// Numerically stable softmax over `potentials / τ`.
    public static func probabilities(potentials: [Float], tau: Float) -> [Float] {
        guard let maxP = potentials.max(), tau > 0 else {
            // Degenerate: uniform.
            let n = potentials.count
            return n == 0 ? [] : Array(repeating: 1 / Float(n), count: n)
        }
        let exps = potentials.map { expf(($0 - maxP) / tau) }
        let sum = exps.reduce(0, +)
        guard sum > 0 else {
            let n = potentials.count
            return Array(repeating: 1 / Float(n), count: n)
        }
        return exps.map { $0 / sum }
    }

    /// Samples an index from `probabilities` using an injected uniform draw in
    /// `[0, 1)` — the single point of non-determinism, isolated here so the loop
    /// stays deterministic under a scripted RNG in tests.
    public static func sample(probabilities: [Float], draw: Double) -> Int {
        guard !probabilities.isEmpty else { return 0 }
        var cumulative: Float = 0
        let d = Float(min(max(draw, 0), 0.999999))
        for (i, p) in probabilities.enumerated() {
            cumulative += p
            if d < cumulative { return i }
        }
        return probabilities.count - 1
    }

    // MARK: - Synthesis primitive

    /// How well a candidate *reconciles* the two poles: its similarity to
    /// whichever pole it is **farther** from, on `[0, 1]`. A genuine synthesis
    /// must sit close to both at once, so it is only as strong as its weaker
    /// connection — `min(sim(c, thesis), sim(c, antithesis))`.
    ///
    /// Honest note on the geometry: "far from both poles yet explaining both" is
    /// contradictory in an embedding metric (the point nearest their midpoint is
    /// still ~45° from each, and moving farther from each moves away from the
    /// midpoint too). So this measures *reconciliation*, not distance — a copy
    /// of one pole scores only the poles' own cross-similarity baseline, and the
    /// synthesis's "transcendence" instead comes from it being a **recurring
    /// idea from elsewhere in the graph** (the caller sources it from memory),
    /// not the current reply.
    public static func synthesisScore(candidate c: Embedding,
                                      thesis: Embedding,
                                      antithesis: Embedding) -> Float {
        let toThesis = normalized(c.cosineSimilarity(to: thesis))
        let toAnti = normalized(c.cosineSimilarity(to: antithesis))
        return min(toThesis, toAnti)
    }

    // MARK: - Resolution

    /// Resolves a scored competition into an outcome, given the standing tension
    /// and a single random draw. Precedence: an emergent **synthesis** (supplied
    /// by the caller once memory exists) resolves the standing contradiction; a
    /// high-tension **stalemate** falls silent; otherwise the basin is
    /// **sampled** from the tension-sharpened softmax.
    ///
    /// `synthesis` is `nil` until milestone 3 wires memory in; passing it here
    /// keeps this function total and independently testable.
    public static func compete(
        scored: [ScoredCandidate],
        tension: Float,
        draw: Double,
        tuning: Tuning = .default,
        synthesis: DialecticalCandidate? = nil,
        forceSynthesis: Bool = false
    ) -> Result {
        let tau = selectionTemperature(tension: tension, tuning: tuning)
        let potentials = scored.map(\.potential)
        let sorted = potentials.sorted(by: >)
        let margin = sorted.count >= 2 ? sorted[0] - sorted[1] : (sorted.first ?? 0)
        let decisive = margin >= tuning.decisiveGap

        func result(_ outcome: DialecticalOutcome) -> Result {
            Result(outcome: outcome, tension: tension, margin: margin,
                   selectionTemperature: tau, decisive: decisive)
        }

        // 1. Synthesis is an event — a genuinely new third idea, or a sustained
        //    convergence the caller has already detected. It resolves the turn.
        if let synthesis, forceSynthesis {
            return result(.synthesized(synthesis))
        }

        // Nothing to say.
        guard !scored.isEmpty else { return result(.silent) }

        // 2. Metastable stalemate: opposed and undecided → hold the tension,
        //    say nothing this turn.
        if scored.count >= 2, margin < tuning.stalemateMargin, tension >= tuning.highTension {
            return result(.silent)
        }

        // 3. Symmetry-breaking: sample a basin. Large margin under low τ ⇒
        //    near-deterministic; near-zero margin ⇒ the draw tips it.
        let probs = probabilities(potentials: potentials, tau: tau)
        let idx = sample(probabilities: probs, draw: draw)
        return result(.spoke(scored[idx].candidate))
    }

    /// L2-normalized mean of a set of embeddings — the "direction the dialogue
    /// has been travelling." Provenance (`modelID`/`version`/`dimension`) is
    /// taken from the first element; embeddings of a different dimension are
    /// skipped rather than trapping. Returns `nil` for an empty set.
    public static func centroid(of embeddings: [Embedding]) -> Embedding? {
        guard let first = embeddings.first else { return nil }
        let dim = first.values.count
        var sum = [Float](repeating: 0, count: dim)
        for e in embeddings where e.values.count == dim {
            for i in 0..<dim { sum[i] += e.values[i] }
        }
        let norm = sqrtf(sum.reduce(0) { $0 + $1 * $1 })
        let values = norm > 1e-6 ? sum.map { $0 / norm } : sum
        return Embedding(values: values, modelID: first.modelID,
                         dimension: dim, version: first.version, seed: 0)
    }
}
