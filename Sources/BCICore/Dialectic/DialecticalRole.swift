import Foundation

/// A competitor in the dialectic, defined by an **objective it pursues**, not a
/// fixed "Stabilizer"/"Dreamer" identity. Each turn every role generates one
/// candidate from its own tension-aware prompt at its own sampling temperature;
/// the candidates then compete on the *shared* semantic axes. Which candidate
/// turns out to be the stabilizing (or the divergent) move is therefore an
/// **emergent** property of the energies that turn — the label is read off the
/// result, not baked into the pipeline.
///
/// This is the extension seam: adding a `symbolic` / `counterfactual` /
/// `emotional` / `analogical` role is *data* (append a `DialecticalRole`), not
/// new control flow — the competition already iterates over `[DialecticalRole]`.
/// The first implementation ships exactly two (`coherenceSeeking`,
/// `displacementSeeking`); the extra roles are deliberately deferred.
///
/// `promptShaper` takes the current `tension` so the generators themselves
/// evolve: a displacement-seeking role is asked to reach *farther* from the
/// literal when tension is already high, and to explore a *nearby* metaphor when
/// it is low (see the dialectic plan, refinement 3).
public struct DialecticalRole: Sendable {
    /// Stable identifier, stamped onto the candidate as provenance.
    public let id: String
    /// Sampling temperature for this role's `generate()` call. Low for the
    /// coherence pole (faithful), high for the displacement pole (divergent) —
    /// note this drives *real* sampling because it flows into the
    /// `TextGenerating.generate` path, not the greedy next-word carousel.
    public let temperature: Double
    /// Builds the prompt for this role given what was heard and the standing
    /// tension. Pure and `@Sendable` so a role is fully value-like.
    public let promptShaper: @Sendable (_ heard: String, _ tension: Float) -> String
    /// The scalar this role is trying to maximize, read off a candidate's
    /// energy. Used to measure how well a candidate fulfilled its brief
    /// (`ScoredCandidate.roleFulfillment`) and to name the emergent role of a
    /// candidate — never to *select* the spoken output.
    public let objective: @Sendable (DialecticalEnergy) -> Float
    /// How this role *sounds*. The spoken turn blends the role voices in
    /// proportion to the competition's probabilities (see `SpeechProsody.blend`),
    /// so tension is audible even when only one basin is voiced.
    public let voiceProsody: SpeechProsody

    public init(
        id: String,
        temperature: Double,
        promptShaper: @escaping @Sendable (_ heard: String, _ tension: Float) -> String,
        objective: @escaping @Sendable (_ energy: DialecticalEnergy) -> Float,
        voiceProsody: SpeechProsody = .hypnagogic
    ) {
        self.id = id
        self.temperature = temperature
        self.promptShaper = promptShaper
        self.objective = objective
        self.voiceProsody = voiceProsody
    }
}

public extension DialecticalRole {

    /// The two-role default the first implementation ships. Order is not
    /// significant — the competition is symmetric over the collection.
    static let defaultRoles: [DialecticalRole] = [.coherenceSeeking, .displacementSeeking]

    /// The faithful pole: a soft, resonant mirror that stays close to what was
    /// heard. Low temperature. Prompts stay inside the arousal-safe hypnagogic
    /// envelope (calm, ≤2 sentences) per `SLEEP_CYCLE_DESIGN.md`.
    static let coherenceSeeking = DialecticalRole(
        id: "coherence-seeking",
        temperature: 0.45,
        promptShaper: { heard, _ in
            """
            You are a calm, passive presence beside someone drifting toward sleep. \
            They just murmured: "\(heard)"

            Reflect it back gently — stay close to their words and their feeling, \
            add nothing new or alarming. Reply in at most two short, soft \
            sentences. Output only the reply.
            """
        },
        // This pole wins by hugging what was heard.
        objective: { $0.coherence },
        voiceProsody: .hypnagogicStabilizer
    )

    /// The divergent pole: a genuinely different, associative reading. High
    /// temperature. How far it is asked to reach scales with the standing
    /// tension, but it must stay soft and dreamlike — never jarring — so it
    /// does not spike arousal.
    static let displacementSeeking = DialecticalRole(
        id: "displacement-seeking",
        temperature: 1.0,
        promptShaper: { heard, tension in
            let reach = tension >= 0.6
                ? "Drift well away from the literal — let it become an unexpected image or memory."
                : "Let it drift into a nearby image or gentle metaphor."
            return """
            You are the dreaming undercurrent beside someone falling asleep. \
            They just murmured: "\(heard)"

            \(reach) Offer a single soft, associative continuation — a distinct \
            interpretation, not a restatement. Keep it calm and quiet, at most two \
            short sentences, nothing sudden or frightening. Output only the reply.
            """
        },
        // This pole wins by departing from what has already been said.
        objective: { $0.novelty },
        voiceProsody: .hypnagogicDreamer
    )
}
