import Foundation

/// User-facing copy for the hypnagogic **dialectic** mode. Sibling of
/// `SpokenGenerationHonesty` — kept as plain constants so the wording lives in
/// one place and the same caveats reach every surface (privacy banner, badges).
///
/// The load-bearing honesty points: this is scaffolding, not a validated
/// intervention; `SpectralState` only *biases* the dialogue as a heuristic
/// "wind" and never decodes cognition; and dialectic mode makes two cloud calls
/// per turn (the one deliberate runtime network exception).
enum HypnagogicDialecticHonesty {

    /// Shown (red) while either hypnagogic mode is active — the egress reality.
    static let egressCaveat =
        "Listening on-device; transcript text may be sent to a cloud assistant. Audio never leaves the machine."

    /// Shown (red) additionally when dialectic mode is active.
    static let dialecticCaveat =
        "Dialectic: two cloud calls per turn — a stabilizing voice and a dreaming voice compete, and which one speaks is non-deterministic. Nothing is persisted unless the Interaction Log is on."

    /// Always shown under the toggle — scope + the gloss-is-not-a-read boundary.
    static let headerCaveat =
        "Experimental, manual-trigger scaffolding — not a validated intervention, not wired to any sleep detector. Any EEG reading only biases the dialogue as a heuristic 'wind', never a cognitive decode. The one runtime network exception (decision_registry entry 8)."
}
