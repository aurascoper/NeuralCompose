import Foundation

/// Free-form, multi-token text generation — distinct from
/// `NextWordPredicting`'s single-token-candidate carousel shape (that
/// protocol stays narrow on purpose; this is a second, independent
/// capability, not a widening of it).
///
/// Implementations: `StubNextWordPredictor` (canned deterministic rewrite,
/// always present), `MLXNextWordPredictor` (real autoregressive generation).
/// Both already conform to `NextWordPredicting`; this is a second protocol
/// view onto the *same instance* — see `PredictorFactory.Resolved.generator`.
public protocol TextGenerating: Sendable {
    var isLive: Bool { get }
    var modelIdentifier: String { get }

    /// Generates free-form continuation/rewrite text for `prompt`.
    /// Implementations must honor cooperative cancellation via
    /// `Task.checkCancellation()`.
    func generate(
        prompt: String,
        maxTokens: Int,
        temperature: Double,
        cancellationID: UUID
    ) async throws -> String
}
