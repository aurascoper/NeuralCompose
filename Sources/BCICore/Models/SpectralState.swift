import Foundation

/// Coarse spectral-band state estimate for one EEG window, produced by
/// classifying an MLX-encoded window against 5 fixed text anchors (see
/// `SpectralStateEstimating`). Cases and order MUST byte-match
/// `Scripts/eeg_spectral.py::STATE_DESCRIPTORS` — the Swift port re-encodes
/// these exact phrases through the app's live `SentenceEmbedder` to rebuild
/// the anchor table the Python-trained encoder was aligned against, so a
/// drift here silently breaks retrieval.
public enum SpectralState: Int, Sendable, Equatable, CaseIterable {
    case drowsyFatigued
    case relaxedWakefulness
    case engagedFocused
    case highCognitiveLoad
    case neutralBaseline

    /// Verbatim match to `STATE_DESCRIPTORS`, same order (index 0-4).
    public var descriptor: String {
        switch self {
        case .drowsyFatigued:
            return "drowsy and fatigued, theta-dominant low-frequency brain activity"
        case .relaxedWakefulness:
            return "relaxed wakefulness, alpha-dominant brain activity"
        case .engagedFocused:
            return "engaged and focused, beta-dominant brain activity"
        case .highCognitiveLoad:
            return "high cognitive load, elevated beta over alpha brain activity"
        case .neutralBaseline:
            return "neutral baseline brain activity with no dominant rhythm"
        }
    }

    /// Short label for UI badges.
    public var badgeLabel: String {
        switch self {
        case .drowsyFatigued:      return "Drowsy/fatigued"
        case .relaxedWakefulness:  return "Relaxed"
        case .engagedFocused:      return "Engaged/focused"
        case .highCognitiveLoad:   return "High load"
        case .neutralBaseline:     return "Neutral"
        }
    }

    /// The "bridge-not-decoder" honesty constraint
    /// (`docs/evaluation/PHASE_3_6_JOINT_EMBEDDING.md`): this label is a
    /// deterministic heuristic gloss over the window's own PSD band ratios,
    /// not a validated read of cognitive state. Attach verbatim wherever a
    /// `SpectralState` reaches a human, so the UI never implies otherwise.
    public static let honestyCaveat =
        "Heuristic gloss over this window's own power-spectral ratios — not a validated cognitive-state read."
}
