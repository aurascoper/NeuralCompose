import Foundation
import BCICore

/// Picks the right `NextWordPredicting` implementation: MLX if real weights
/// exist on disk and init succeeds, stub otherwise.
public enum PredictorFactory {

    /// Default directory for MLX model weights, relative to the app working
    /// directory. Override with `NEURALCOMPOSE_MLX_MODEL` env var (folder
    /// name) or with the explicit argument to `live(modelDirectory:)`.
    public static let defaultMLXModelName = "Qwen2.5-0.5B-Instruct-4bit"
    public static let defaultMLXBaseDir   = "Models"

    public struct Resolved: Sendable {
        public let predictor: any NextWordPredicting
        /// Same underlying instance as `predictor`, exposed through the
        /// separate `TokenEmbeddingProviding` protocol — see that protocol's
        /// doc comment for why this is a distinct, diagnostics-only seam
        /// rather than a method on `NextWordPredicting` itself. Both
        /// `MLXNextWordPredictor` and `StubNextWordPredictor` conform, so
        /// this is never nil.
        public let embeddingProvider: any TokenEmbeddingProviding
        /// Same underlying instance as `predictor` again, exposed through
        /// `TextGenerating` — the free-form multi-pass generation seam
        /// `DialecticEngine` uses. Kept separate from `NextWordPredicting`
        /// for the same reason `embeddingProvider` is separate: a distinct
        /// capability with a distinct cost profile, not a widening of the
        /// carousel's single-forward-pass protocol.
        public let generator: any TextGenerating
        public let tokenizer: any TokenizerProviding
        public let kind: PipelineMode.Predictor
        public let warning: String?
    }

    public static func live(
        modelDirectory: URL? = nil
    ) async -> Resolved {
        let chosenDir: URL? = modelDirectory ?? resolveDefaultDirectory()

        let tokenizer = TokenizerService(modelDirectory: chosenDir)

        guard let dir = chosenDir, FileManager.default.fileExists(atPath: dir.path) else {
            let stub = StubNextWordPredictor()
            return Resolved(
                predictor: stub,
                embeddingProvider: stub,
                generator: stub,
                tokenizer: tokenizer,
                kind: .stub,
                warning: nil
            )
        }

        do {
            let mlx = try await MLXNextWordPredictor(modelDirectory: dir)
            return Resolved(
                predictor: mlx,
                embeddingProvider: mlx,
                generator: mlx,
                tokenizer: tokenizer,
                kind: .mlx,
                warning: nil
            )
        } catch {
            let reason = (error as? BCIError)?.description ?? error.localizedDescription
            BCILog.predictor.notice("MLX init failed (\(reason, privacy: .public)); using stub")
            let stub = StubNextWordPredictor()
            return Resolved(
                predictor: stub,
                embeddingProvider: stub,
                generator: stub,
                tokenizer: tokenizer,
                kind: .stub,
                warning: "MLX present but failed to load: \(reason)"
            )
        }
    }

    /// Where we look for MLX weights, in priority order:
    ///   1. `NEURALCOMPOSE_MLX_MODEL` env var: an absolute path *or* a folder
    ///      name resolved under `Models/`.
    ///   2. `Models/<defaultMLXModelName>/`.
    private static func resolveDefaultDirectory() -> URL? {
        let env = ProcessInfo.processInfo.environment["NEURALCOMPOSE_MLX_MODEL"]
        if let env = env, !env.isEmpty {
            if env.hasPrefix("/") {
                return URL(fileURLWithPath: env)
            }
            return URL(fileURLWithPath: defaultMLXBaseDir).appendingPathComponent(env)
        }
        return URL(fileURLWithPath: defaultMLXBaseDir).appendingPathComponent(defaultMLXModelName)
    }
}
