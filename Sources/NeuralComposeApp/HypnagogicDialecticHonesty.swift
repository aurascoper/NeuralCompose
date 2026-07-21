import Foundation

/// User-facing copy for the hypnagogic **dialectic** mode. Sibling of
/// `SpokenGenerationHonesty` — kept as plain constants so the wording lives in
/// one place and the same caveats reach every surface (privacy banner, badges).
///
/// The load-bearing honesty points: this is scaffolding, not a validated
/// intervention; `SpectralState` only *biases* the dialogue as a heuristic
/// "wind" and never decodes cognition; and dialectic mode makes two cloud calls
/// per turn — THREE for Reflective, which adds a non-voiced introspective Witness
/// (WITNESS.md) — the one deliberate runtime network exception.
enum HypnagogicDialecticHonesty {

    /// Shown (red) while either hypnagogic mode is active — the egress reality.
    static let egressCaveat =
        "Listening on-device; transcript text may be sent to a cloud assistant. Audio never leaves the machine."

    /// Shown (red) additionally when dialectic mode is active. Reflective adds a
    /// third, non-voiced Witness call (`ContextProfile.witnessEnabled`), so it
    /// discloses THREE calls; Focused / Contemplative disclose two.
    static func dialecticCaveat(reflective: Bool) -> String {
        let voices = reflective
            ? "three cloud calls per turn — a stabilizing voice and a dreaming voice compete, plus a third, non-voiced Witness that observes but is never spoken"
            : "two cloud calls per turn — a stabilizing voice and a dreaming voice compete"
        return "Dialectic: \(voices), and which one speaks is non-deterministic. Nothing is persisted unless the Interaction Log is on."
    }

    /// Always shown under the toggle — scope + the gloss-is-not-a-read boundary.
    static let headerCaveat =
        "Experimental, manual-trigger scaffolding — not a validated intervention, not wired to any sleep detector. Any EEG reading only biases the dialogue as a heuristic 'wind', never a cognitive decode. The one runtime network exception (decision_registry entry 8)."
}
