import Foundation

/// Output of a deterministic state → generation rule table (see
/// `SignalQualityGenerationRules` in `NeuralComposeApp`). No learning, no
/// forecasting, no history — a pure function's result, cheap enough to
/// recompute on every state change.
public struct GenerationAdaptation: Sendable, Equatable {
    public var maxCandidates: Int
    public var temperature: Double
    /// Soft steering text prepended to the model's prompt context ahead of
    /// the user's composed sentence (see
    /// `TextCompositionController.requestPredictions`). NOT a chat "system"
    /// message — `NextWordPredicting.predictNextWords` is a raw continuation
    /// forward pass, not an instruct/chat completion, so this only weakly
    /// primes the distribution rather than guaranteeing an instruction is
    /// followed. Empty string means "no additional priming."
    public var styleInstruction: String

    public init(maxCandidates: Int, temperature: Double, styleInstruction: String = "") {
        self.maxCandidates = maxCandidates
        self.temperature = temperature
        self.styleInstruction = styleInstruction
    }

    /// Raw/default behavior — identical to `TextCompositionController.Config`'s
    /// own defaults. This is what "adaptive mode disabled" and "healthy
    /// signal, no adaptation needed" both resolve to, so the two can never
    /// silently drift apart.
    public static let raw = GenerationAdaptation(maxCandidates: 3, temperature: 0.7, styleInstruction: "")
}
