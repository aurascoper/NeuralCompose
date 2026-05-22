import Foundation
import BCICore

#if canImport(MLX) && canImport(MLXLLM) && canImport(MLXLMCommon)
import MLX
import MLXLLM
import MLXLMCommon
#endif

/// MLX-Swift-backed next-word predictor.
///
/// This is the **only** file in the codebase that touches the MLX runtime.
/// MLX-Swift's `MLXLLM` / `MLXLMCommon` API surface is still evolving;
/// rather than guess the exact signatures of the current release and risk a
/// build break, we keep this adapter:
///
///   1. *compilable* against any pinned MLX-Swift version — it only
///      references MLX symbols inside the `#if canImport(...)` block, and
///      we restrict ourselves to the most stable types (`MLX.GPU` config);
///
///   2. *safe at init* — by default it throws `BCIError.predictorInitFailed`,
///      which `PredictorFactory.live()` catches to substitute the stub. The
///      app keeps working end-to-end without MLX.
///
/// To enable real MLX generation:
///   • Pick an MLX model (see MODEL_SETUP.md) and place it in `Models/`.
///   • Replace the body of `loadAndGenerate(context:k:temperature:)` below
///     with the matching loader + generate calls for your pinned
///     `mlx-swift-examples` version. Keep this file's *signature* stable —
///     the protocol `NextWordPredicting` is what the rest of the codebase
///     talks to, and that does not change.
///
/// Threading: actor. Generation is serialized — running two generations at
/// once on the Apple GPU would just thrash.
public actor MLXNextWordPredictor: NextWordPredicting {

    public nonisolated let isLive: Bool = true
    public nonisolated let modelIdentifier: String

    private let modelDirectory: URL

    public init(modelDirectory: URL) async throws {
        guard FileManager.default.fileExists(atPath: modelDirectory.path) else {
            throw BCIError.predictorWeightsMissing(path: modelDirectory.path)
        }
        self.modelIdentifier = modelDirectory.lastPathComponent
        self.modelDirectory = modelDirectory

        #if canImport(MLX) && canImport(MLXLLM) && canImport(MLXLMCommon)
        throw BCIError.predictorInitFailed(
            reason: "MLXNextWordPredictor: integration stub — wire up MLXLLM loader for your pinned version (see file comment)"
        )
        #else
        throw BCIError.predictorInitFailed(reason: "MLX modules not importable")
        #endif
    }

    public func predictNextWords(
        context: String,
        maxCandidates: Int,
        temperature: Double,
        cancellationID: UUID
    ) async throws -> [PredictedWord] {
        try Task.checkCancellation()
        // Unreachable in current build — `init` always throws so the factory
        // substitutes the stub. Implement once you've wired up loading.
        throw BCIError.predictorInferenceFailed(reason: "MLX adapter not initialized")
    }
}
