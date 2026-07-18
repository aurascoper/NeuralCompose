import BCICore

/// Milestone-B rule table: `SpectralState` (a heuristic gloss over this
/// window's own PSD band ratios — see `SpectralState.honestyCaveat`, NOT a
/// validated cognitive-state read) → generation adaptation.
///
/// Conservative-only, matching `SignalQualityGenerationRules`'s existing
/// philosophy: this only ever hedges toward simpler generation, never
/// richer. `.highCognitiveLoad`/`.drowsyFatigued` simplify (fewer, lower-
/// temperature candidates); `.relaxedWakefulness`/`.engagedFocused`/
/// `.neutralBaseline` all map to `.raw` — the new signal only ever narrows
/// output, it never gets to unlock something wider than the default.
public enum SpectralGenerationRules {
    public static func adaptation(for state: SpectralState) -> GenerationAdaptation {
        switch state {
        case .highCognitiveLoad:
            return GenerationAdaptation(
                maxCandidates: 2,
                temperature: 0.4,
                styleInstruction: "Prefer short, simple, high-frequency words."
            )
        case .drowsyFatigued:
            return GenerationAdaptation(
                maxCandidates: 2,
                temperature: 0.3,
                styleInstruction: "Prefer the single most common, simplest next word."
            )
        case .relaxedWakefulness, .engagedFocused, .neutralBaseline:
            return .raw
        }
    }
}

/// Combines the two Milestone A/B state sources into one
/// `GenerationAdaptation`. A pure function, directly unit-testable in
/// isolation — Milestone A never needed one since it only had a single
/// state source.
public enum AdaptiveGenerationCombination {
    public static func adaptation(
        signalQuality: SignalQuality?,
        spectralState: SpectralState?
    ) -> GenerationAdaptation {
        // Absolute safety floor: the artifact gate only rejects
        // too-*high*-amplitude windows (blink/EOG/movement), not a
        // disconnected/no-contact electrode — so a spectral opinion could
        // otherwise spuriously survive on a dead channel. `.lost` always
        // wins regardless of what the spectral estimator says.
        if signalQuality == .lost {
            return SignalQualityGenerationRules.adaptation(for: .lost)
        }
        if let spectralState {
            return SpectralGenerationRules.adaptation(for: spectralState)
        }
        return SignalQualityGenerationRules.adaptation(for: signalQuality)
    }
}
