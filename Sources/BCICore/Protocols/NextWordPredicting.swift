import Foundation

/// Local LLM next-word predictor. The single abstraction that protects every
/// other module from MLX-Swift API drift.
///
/// Implementations: `StubNextWordPredictor` (always present, in-process),
/// `MLXNextWordPredictor` (optional, real model). The factory swaps them
/// transparently when weights are missing or initialization fails.
public protocol NextWordPredicting: Sendable {

    /// True if this is the MLX-backed implementation; false if it's the stub.
    var isLive: Bool { get }

    /// Short identifier for the privacy banner / metrics view.
    var modelIdentifier: String { get }

    /// Suggest up to `maxCandidates` next words for `context`, ranked by
    /// probability. `cancellationID` lets a stale call be cancelled when the
    /// user selects a different token before this one returns. Implementations
    /// must honor cooperative cancellation via `Task.checkCancellation()`.
    func predictNextWords(
        context: String,
        maxCandidates: Int,
        temperature: Double,
        cancellationID: UUID
    ) async throws -> [PredictedWord]
}
