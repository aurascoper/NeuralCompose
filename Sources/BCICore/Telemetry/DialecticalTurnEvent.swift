import Foundation

/// Opt-in record of one dialectical turn — the "history of transformations"
/// the plan calls for: not just the chosen reply, but the thesis, the
/// antithesis, their scored energies, the tension, and which basin (or silence,
/// or synthesis) resolved it. A trajectory of these is a path through the
/// dialogue's semantic space.
///
/// Deliberately parallel to `TelemetryEvent` (word-commit logging) rather than
/// an extension of it, and — like that type — it carries only text + scalar
/// scores, never raw embeddings. It is written only when the interaction-logging
/// toggle is on (see `DialecticalTurnLogging`).
public struct DialecticalTurnEvent: Codable, Sendable, Equatable {

    public struct Candidate: Codable, Sendable, Equatable {
        public let text: String
        public let roleID: String
        public let coherence: Float
        public let resonance: Float
        public let novelty: Float
        public let potential: Float
    }

    public let index: Int
    public let heard: String
    public let candidates: [Candidate]
    public let tension: Float
    public let margin: Float
    public let selectionTemperature: Float
    /// The `SpectralState` gloss scalar in force this turn (0.5 = neutral / no
    /// EEG). A bias signal, never a cognitive read.
    public let glossScalar: Float
    /// Raw estimator state behind `glossScalar` — the badge label
    /// ("Relaxed" / "Neutral" / …) or nil when the estimator produced nothing
    /// (stub / no EEG). Disambiguates a real "Neutral" from an absent state,
    /// which `glossScalar` (0.5 for both) cannot. Optional so old logs still decode.
    public let spectralState: String?
    /// `"spoke:<roleID>"`, `"synthesized:<roleID>"`, or `"silent"`.
    public let outcome: String
    /// The words actually voiced (nil on a silent turn).
    public let spokenText: String?
    /// The Witness's observation ("what both poles avoided") — Reflective profile
    /// only, nil otherwise. Text only. Optional so old logs still decode.
    public let witnessFinding: String?
    /// Reflective metric: distance of the witness finding from the spoken text.
    public let witnessDistance: Float?
    /// Reflexive metric: how much the utterance collapsed toward the reply centroid.
    public let selfSimilarity: Float?
    /// Whether the Witness ran this turn (Reflective) — distinguishes a broken /
    /// finding-less witness from a disabled one. nil in pre-Witness logs.
    public let witnessAttempted: Bool?

    public init(_ c: DialecticalCompetition) {
        self.index = c.index
        self.heard = c.heard
        self.candidates = c.scored.map {
            Candidate(text: $0.candidate.text, roleID: $0.candidate.roleID,
                      coherence: $0.energy.coherence, resonance: $0.energy.resonance,
                      novelty: $0.energy.novelty, potential: $0.potential)
        }
        self.tension = c.tension
        self.margin = c.margin
        self.selectionTemperature = c.selectionTemperature
        self.glossScalar = c.glossScalar
        self.spectralState = c.spectralState?.badgeLabel
        self.witnessFinding = c.witnessFinding
        self.witnessDistance = c.witnessDistance
        self.selfSimilarity = c.selfSimilarity
        self.witnessAttempted = c.witnessAttempted
        switch c.outcome {
        case let .spoke(cand):
            self.outcome = "spoke:\(cand.roleID)"
            self.spokenText = cand.text
        case let .synthesized(cand):
            self.outcome = "synthesized:\(cand.roleID)"
            self.spokenText = cand.text
        case .silent:
            self.outcome = "silent"
            self.spokenText = nil
        }
    }
}

/// Sink for `DialecticalTurnEvent`s — the opt-in persistence seam, parallel to
/// `InteractionLogging`. The default `NullDialecticalTurnLogger` drops
/// everything, so the loop persists nothing unless a real sink is injected.
public protocol DialecticalTurnLogging: Sendable {
    func log(_ event: DialecticalTurnEvent) async
}

public struct NullDialecticalTurnLogger: DialecticalTurnLogging {
    public init() {}
    public func log(_ event: DialecticalTurnEvent) async {}
}
