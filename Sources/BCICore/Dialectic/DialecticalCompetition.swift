import Foundation

/// Value types for the hypnagogic **dialectic** loop — a persistent dynamical
/// process where several generators pursuing different *objectives* compete each
/// turn, rather than one generator producing one mirror reply.
///
/// These are pure BCICore value types (no MLX, no AVFoundation), mirroring
/// `DialecticEngine`'s isolation discipline. `DialecticEngine` (thesis →
/// antithesis → single synthesis) is left untouched; this is its non-collapsing
/// sibling — contradiction is allowed to persist across turns and synthesis
/// becomes a rare *event*, not a per-turn operation.

// MARK: - Weights

/// The three semantic axes a candidate is scored on, weighted into a single
/// dialectical potential `D`. Held as a value so the same shape can be a fixed
/// default now (milestones 1–4) and an evolving vector field later (milestone 5,
/// `DialecticalField`). Convention: all axis inputs are in `[0, 1]`.
public struct DialecticalWeights: Sendable, Equatable {
    /// Weight on fidelity to what was just heard.
    public var coherence: Float
    /// Weight on fit to the dialogue's accumulated trajectory.
    public var resonance: Float
    /// Weight on departure from what the machine has already said.
    public var novelty: Float

    public init(coherence: Float, resonance: Float, novelty: Float) {
        self.coherence = coherence
        self.resonance = resonance
        self.novelty = novelty
    }

    /// Neutral starting point (used directly through milestone 4, and as the
    /// field's seed in milestone 5). Coherence leads, novelty is a strong
    /// second so the displacement pole is a real contender, resonance is the
    /// gentlest pull.
    public static let balanced = DialecticalWeights(coherence: 1.0, resonance: 0.6, novelty: 0.8)
}

// MARK: - Energy

/// One candidate's position on the three axes, each normalized to `[0, 1]`
/// (see `DialecticalDynamics.energy`). The candidate's dialectical potential is
/// `⟨weights, energy⟩` — that scalar is what the competition samples over.
public struct DialecticalEnergy: Sendable, Equatable {
    public let coherence: Float   // fidelity to `heard`
    public let resonance: Float   // fit to the history centroid
    public let novelty: Float     // distance from the reply centroid

    public init(coherence: Float, resonance: Float, novelty: Float) {
        self.coherence = coherence
        self.resonance = resonance
        self.novelty = novelty
    }

    /// The weighted dialectical potential `D = ⟨weights, energy⟩`.
    public func potential(_ w: DialecticalWeights) -> Float {
        w.coherence * coherence + w.resonance * resonance + w.novelty * novelty
    }
}

// MARK: - Candidate

/// A single generated continuation plus its embedding and the id of the role
/// that produced it. `roleID` is the *provenance* of the candidate — which
/// objective it was generated to pursue — not a fixed identity of the spoken
/// output: which candidate turns out to be "the stabilizing move" emerges from
/// the energies each turn (see `DialecticalRole`).
public struct DialecticalCandidate: Sendable, Equatable {
    public let text: String
    public let embedding: Embedding
    public let roleID: String

    public init(text: String, embedding: Embedding, roleID: String) {
        self.text = text
        self.embedding = embedding
        self.roleID = roleID
    }
}

/// A candidate paired with its scored energy and resulting potential. Kept as a
/// single struct (rather than parallel arrays) so index alignment between a
/// candidate and its score can never drift.
public struct ScoredCandidate: Sendable, Equatable {
    public let candidate: DialecticalCandidate
    public let energy: DialecticalEnergy
    public let potential: Float
    /// How well this candidate satisfied the objective of the role that
    /// produced it (`role.objective(energy)`). Diagnostic for now — it lets a
    /// later stage notice a role that failed its own brief (e.g. a
    /// displacement-seeking pass that produced something un-novel because the
    /// model refused to diverge).
    public let roleFulfillment: Float

    public init(candidate: DialecticalCandidate, energy: DialecticalEnergy,
                potential: Float, roleFulfillment: Float) {
        self.candidate = candidate
        self.energy = energy
        self.potential = potential
        self.roleFulfillment = roleFulfillment
    }
}

// MARK: - Outcome

/// What a turn resolves to. Note `silent`: a high-tension stalemate is a
/// *legitimate* non-resolution — the loop says nothing and carries the
/// unresolved tension into the next turn (metastability). Synthesis is the rare
/// emergent third idea, not the default.
public enum DialecticalOutcome: Sendable, Equatable {
    /// A basin won (decisively, or by a perturbation near equilibrium).
    case spoke(DialecticalCandidate)
    /// Metastable stalemate — no speech this turn; tension persists.
    case silent
    /// An emergent third idea (far from both poles yet explaining both) or a
    /// sustained low-tension convergence resolved the standing contradiction.
    case synthesized(DialecticalCandidate)
}

// MARK: - Turn record

/// The full record of one competition — the point this turn adds to the
/// dialogue's trajectory. Persisted (opt-in) as a `DialecticalTurnEvent` and
/// used in-session to grow the semantic-graph memory.
public struct DialecticalCompetition: Sendable, Equatable {
    public let index: Int
    public let heard: String
    public let scored: [ScoredCandidate]
    public let tension: Float
    /// Gap between the top two potentials — how decisive the field was this
    /// turn. Small margin + high tension is the metastable / bifurcation zone.
    public let margin: Float
    /// Selection temperature actually used (a function of tension).
    public let selectionTemperature: Float
    public let outcome: DialecticalOutcome
    /// The `SpectralState` gloss scalar in force this turn. Recorded, never used
    /// to *select*.
    public let glossScalar: Float
    /// The raw `SpectralState` behind `glossScalar` this turn, or nil when the
    /// estimator produced nothing (stub estimator / no live EEG / rejected
    /// window). Recorded purely for observability: `glossScalar` maps both nil
    /// *and* a genuine `.neutralBaseline` to 0.5, so it alone cannot tell "the
    /// EEG said neutral" from "there was no EEG" — this field can.
    public let spectralState: SpectralState?

    public init(index: Int, heard: String, scored: [ScoredCandidate], tension: Float,
                margin: Float, selectionTemperature: Float, outcome: DialecticalOutcome,
                glossScalar: Float, spectralState: SpectralState? = nil) {
        self.index = index
        self.heard = heard
        self.scored = scored
        self.tension = tension
        self.margin = margin
        self.selectionTemperature = selectionTemperature
        self.outcome = outcome
        self.glossScalar = glossScalar
        self.spectralState = spectralState
    }
}
