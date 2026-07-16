import Foundation
import BCICore

/// Picks the right `NextWordPredicting` implementation: MLX if real weights
/// exist on disk and init succeeds, stub otherwise.
public enum PredictorFactory {

    /// Base directory for MLX model weights, relative to the app working
    /// directory. The model name within it comes from
    /// `MLXBackend.defaultModelName`, overridable per-call via
    /// `NEURALCOMPOSE_MLX_MODEL` (folder name or absolute path) or the
    /// explicit argument to `live(modelDirectory:)`.
    public static let defaultMLXBaseDir = "Models"

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
        modelDirectory: URL? = nil,
        backend: MLXBackend? = nil
    ) async -> Resolved {
        let chosenBackend = backend ?? resolveBackendFromEnvironment()
        let chosenDir: URL? = modelDirectory ?? resolveDefaultDirectory(backend: chosenBackend)

        let tokenizer = TokenizerService(modelDirectory: chosenDir)

        guard let dir = chosenDir, FileManager.default.fileExists(atPath: dir.path) else {
            return stubResolved(tokenizer: tokenizer, warning: nil)
        }

        // MLX's C++/Metal layer can fail to load its default metallib in a
        // way that is NOT a catchable Swift `Error` — it aborts the whole
        // process before `MLXNextWordPredictor.init`'s own `do/catch` ever
        // gets a chance to run. Prediction is optional; the application
        // launching is not. So the real load is only attempted in-process
        // after a disposable child-process probe has already survived it —
        // if the probe crashes, so would we, and we fall back to the stub
        // instead. The probe launches the standalone `MLXProbe` executable
        // (`Sources/MLXProbe/main.swift`) — a purpose-built, minimal binary
        // — rather than re-invoking the app's own binary with an env var,
        // so the app never needs to detect "am I secretly a probe right
        // now" in its own entry point.
        switch await runInitProbeSubprocess(modelDirectory: dir, backend: chosenBackend) {
        case .success(let metrics):
            BCILog.predictor.notice("""
                MLX probe succeeded: \(metrics.modelIdentifier, privacy: .public) \
                modelLoad=\(metrics.modelLoadTime, privacy: .public)s \
                firstToken=\(metrics.firstTokenLatency, privacy: .public)s \
                throughput=\(metrics.tokensPerSecond, privacy: .public) tok/s
                """)
            do {
                let mlx = try await MLXNextWordPredictor(
                    modelDirectory: dir, configuration: chosenBackend.configuration
                )
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
                BCILog.predictor.notice("MLX init failed after a successful probe (\(reason, privacy: .public)); using stub")
                return stubResolved(tokenizer: tokenizer, warning: "MLX present but failed to load: \(reason)")
            }
        case .timeout:
            BCILog.predictor.notice("MLX probe timed out for \(dir.path, privacy: .public); using stub")
            return stubResolved(tokenizer: tokenizer, warning: "MLX probe timed out; using stub predictor.")
        case .crashed(let signal):
            BCILog.predictor.notice("MLX probe crashed (signal \(signal, privacy: .public)) for \(dir.path, privacy: .public); using stub")
            return stubResolved(tokenizer: tokenizer, warning: "MLX probe crashed (signal \(signal)); using stub predictor.")
        case .failed(let reason):
            BCILog.predictor.notice("MLX probe failed (\(reason, privacy: .public)) for \(dir.path, privacy: .public); using stub")
            return stubResolved(tokenizer: tokenizer, warning: "MLX probe failed: \(reason)")
        }
    }

    private static func stubResolved(tokenizer: any TokenizerProviding, warning: String?) -> Resolved {
        let stub = StubNextWordPredictor()
        return Resolved(
            predictor: stub,
            embeddingProvider: stub,
            generator: stub,
            tokenizer: tokenizer,
            kind: .stub,
            warning: warning
        )
    }

    /// Spawns the standalone `MLXProbe` binary (`--json <modelDirectory>`)
    /// as a disposable child process and races it against a timeout,
    /// returning a `ProbeResult` that distinguishes success, a parseable
    /// failure, a timeout, and a crash-by-signal. Thin wrapper over
    /// `SubprocessProbe` — see that type for the actual Process/Pipe/
    /// timeout/crash-detection mechanism, shared with the spectral state
    /// estimator's factory rather than duplicated.
    private static func runInitProbeSubprocess(
        modelDirectory: URL, backend: MLXBackend, timeoutSeconds: Double = 20.0
    ) async -> ProbeResult {
        guard let probeBinary = SubprocessProbe.locateSiblingBinary(named: "MLXProbe") else {
            return .failed(reason: "MLXProbe binary not found alongside the app executable")
        }
        return await SubprocessProbe.run(
            binary: probeBinary,
            arguments: ["--json", "--backend", backend.rawValue, modelDirectory.path],
            timeoutSeconds: timeoutSeconds
        )
    }

    /// Where we look for MLX weights, in priority order:
    ///   1. `NEURALCOMPOSE_MLX_MODEL` env var: an absolute path *or* a folder
    ///      name resolved under `Models/`. Applies to either backend.
    ///   2. `Models/<backend.defaultModelName>/`.
    private static func resolveDefaultDirectory(backend: MLXBackend) -> URL? {
        let env = ProcessInfo.processInfo.environment["NEURALCOMPOSE_MLX_MODEL"]
        if let env = env, !env.isEmpty {
            if env.hasPrefix("/") {
                return URL(fileURLWithPath: env)
            }
            return URL(fileURLWithPath: defaultMLXBaseDir).appendingPathComponent(env)
        }
        return URL(fileURLWithPath: defaultMLXBaseDir)
            .appendingPathComponent(backend.defaultModelName)
    }

    /// `NEURALCOMPOSE_MLX_BACKEND` env var (`"qwen"`/`"gemma"`,
    /// case-insensitive). Unset or unrecognized falls back to `.qwen` —
    /// same "fall back to known-good" pattern as
    /// `AppContainer.profileFromEnvironment()`.
    private static func resolveBackendFromEnvironment() -> MLXBackend {
        guard let raw = ProcessInfo.processInfo.environment["NEURALCOMPOSE_MLX_BACKEND"] else {
            return .qwen
        }
        return MLXBackend(rawValue: raw.lowercased()) ?? .qwen
    }
}
