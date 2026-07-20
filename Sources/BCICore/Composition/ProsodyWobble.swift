import Foundation

/// Confidence-*wobble* prosody planner (voice de-robotify, Stage 2).
///
/// A voice reads as robotic when every clause lands at the same confidence
/// (dialectic turn 35: "vary how hard I commit — hedge the guesses, flatten out
/// only where I actually know, let the register itself wobble"). This splits
/// text into phrases and gives each its own `SpeechProsody`, varied by a
/// lightweight *commitment* estimate:
///
/// - **Hedged** clauses ("maybe", "I think", "sort of", questions) → slower,
///   softer, a slightly *rising* pitch and a beat before them (audible
///   uncertainty).
/// - **Committed** clauses ("clearly", "must", "never", plain declaratives) →
///   a touch quicker, fuller, a slightly *falling* pitch (audible conviction).
///
/// A tiny per-phrase jitter breaks adjacency-monotony even at neutral commitment,
/// so consecutive sentences never land identically. Pure Swift, AVFoundation-free
/// (drives the existing per-chunk `speak(_:prosody:)` path), spy-testable.
public enum ProsodyWobble {

    /// Split `text` into phrases (`HypnagogicDialogueLoop.chunk`) and assign each
    /// a commitment-varied prosody around `base`.
    public static func plan(_ text: String, base: SpeechProsody = .wakingCoherent) -> [(phrase: String, prosody: SpeechProsody)] {
        HypnagogicDialogueLoop.chunk(text).enumerated().map { index, phrase in
            (phrase, prosody(for: phrase, base: base, index: index))
        }
    }

    /// Commitment of a phrase in `[-1, 1]`: negative = hedged/uncertain, positive
    /// = committed/certain. Lexical hedge/intensifier counting + a question penalty.
    public static func commitment(of phrase: String) -> Double {
        let words = phrase.lowercased().split { !$0.isLetter && $0 != "'" }.map(String.init)
        var score = 0.0
        for w in words {
            if hedges.contains(w) { score -= 1 }
            if intensifiers.contains(w) { score += 1 }
        }
        if phrase.contains("?") { score -= 0.6 }   // a question is inherently less committed
        return max(-1, min(1, score))
    }

    // MARK: - Internals

    private static func prosody(for phrase: String, base: SpeechProsody, index: Int) -> SpeechProsody {
        let c = Float(commitment(of: phrase))                     // -1 hedged … +1 certain
        let jitter: Float = index % 2 == 0 ? 0 : -0.02            // break adjacency-monotony
        return SpeechProsody(
            rate: clamp((base.rate ?? 0.5) + c * 0.05 + jitter, 0.30, 0.60),          // certain a touch quicker
            pitchMultiplier: clamp((base.pitchMultiplier ?? 1.0) - c * 0.06, 0.85, 1.15), // hedged rises, certain falls
            volume: clamp((base.volume ?? 0.9) + c * 0.08, 0.60, 1.00),               // certain fuller
            preUtteranceDelay: max(0, (base.preUtteranceDelay ?? 0.1) + (c < 0 ? 0.06 : 0)) // a beat before a hedge
        )
    }

    private static func clamp(_ x: Float, _ lo: Float, _ hi: Float) -> Float { min(max(x, lo), hi) }

    private static let hedges: Set<String> = [
        "maybe", "perhaps", "might", "could", "possibly", "probably", "seems", "seem",
        "guess", "think", "suppose", "sort", "kind", "somewhat", "apparently",
        "presumably", "likely", "roughly", "approximately", "unsure", "arguably", "may",
    ]
    private static let intensifiers: Set<String> = [
        "clearly", "obviously", "definitely", "certainly", "always", "never", "must",
        "exactly", "precisely", "undoubtedly", "surely", "absolutely", "is", "will",
    ]
}
