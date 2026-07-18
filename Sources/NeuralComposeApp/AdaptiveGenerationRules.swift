import BCICore

/// Milestone-A rule table: coarse EEG *signal quality* (electrode contact /
/// hardware confidence — an RMS-derived bucket, see `SignalQuality`'s doc
/// comment — NOT a cognitive-state read) → generation adaptation.
///
/// When signal quality is degraded, the intent classifier feeding word
/// commits is noisier too, so this hedges toward safer generations (fewer,
/// higher-probability, simpler candidates) rather than claiming anything
/// about the user's mental state. `.healthy` reproduces
/// `GenerationAdaptation.raw` exactly, so a healthy signal and "adaptation
/// off" are indistinguishable to the predictor, by design.
public enum SignalQualityGenerationRules {
    public static func adaptation(for quality: SignalQuality?) -> GenerationAdaptation {
        switch quality {
        case .none:
            return .raw
        case .healthy:
            return .raw
        case .poor:
            return GenerationAdaptation(
                maxCandidates: 3,
                temperature: 0.5,
                styleInstruction: "Prefer short, common, high-confidence words."
            )
        case .lost:
            return GenerationAdaptation(
                maxCandidates: 2,
                temperature: 0.3,
                styleInstruction: "Prefer the single most common, simplest next word."
            )
        }
    }
}
