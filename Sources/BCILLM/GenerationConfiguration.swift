import Foundation

/// Per-model-family generation knobs, owned by whichever `MLXBackend` a
/// predictor was constructed for. Split out once a second backend (Gemma)
/// made it clear these were model metadata, not a single constant — see
/// `MLXBackend`.
public struct GenerationConfiguration: Sendable, Equatable {
    /// `Set`, not `[String]` — matches `ModelConfiguration.extraEOSTokens`
    /// (vendored `MLXLMCommon`) exactly, so this passes straight through
    /// without a conversion at the call site.
    public let extraEOSTokens: Set<String>
    public let repetitionPenalty: Float

    public init(extraEOSTokens: Set<String>, repetitionPenalty: Float) {
        self.extraEOSTokens = extraEOSTokens
        self.repetitionPenalty = repetitionPenalty
    }

    /// `<|im_end|>` — Qwen's ChatML end-of-turn token.
    public static let qwen = GenerationConfiguration(
        extraEOSTokens: ["<|im_end|>"], repetitionPenalty: 1.3
    )

    /// `<end_of_turn>` — Gemma's end-of-turn token (every Gemma catalog
    /// entry in the vendored `mlx-swift-examples` registers the same
    /// string). Same repetition penalty as `.qwen` for now — no evidence
    /// yet that Gemma needs a different value; that's what a future
    /// evaluation harness comparing both backends is for, not something to
    /// guess at here.
    public static let gemma = GenerationConfiguration(
        extraEOSTokens: ["<end_of_turn>"], repetitionPenalty: 1.3
    )
}
