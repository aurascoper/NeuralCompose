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
            return Resolved(
                predictor: StubNextWordPredictor(),
                tokenizer: tokenizer,
                kind: .stub,
                warning: nil
            )
        }

        do {
            let mlx = try await MLXNextWordPredictor(modelDirectory: dir)
            return Resolved(
                predictor: mlx,
                tokenizer: tokenizer,
                kind: .mlx,
                warning: nil
            )
        } catch {
            let reason = (error as? BCIError)?.description ?? error.localizedDescription
            BCILog.predictor.notice("MLX init failed (\(reason, privacy: .public)); using stub")
            return Resolved(
                predictor: StubNextWordPredictor(),
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
