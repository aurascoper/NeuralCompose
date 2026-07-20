import Foundation
import BCICore

/// Picks the right `SpectralStateEstimating` implementation: the real
/// MLX-backed encoder if `Models/EEGEncoder/` exists, its crash-safety probe
/// succeeds, and the anchor space is trusted; the stub otherwise. Mirrors
/// `PredictorFactory` exactly — same stub-by-default shape, same
/// disposable-subprocess crash-safety probe (via the shared
/// `SubprocessProbe`, using the dedicated `SpectralProbe` binary rather than
/// `MLXProbe` — see `Package.swift`'s comment on why they're kept separate).
public enum SpectralStateEstimatorFactory {

    public enum Kind: String, Sendable {
        case mlx
        case stub
    }

    /// `Models/EEGEncoder/`, overridable via `NEURALCOMPOSE_SPECTRAL_MODEL`
    /// (an absolute path, or a folder name resolved under `Models/`) — same
    /// convention as `PredictorFactory`'s `NEURALCOMPOSE_MLX_MODEL`.
    public static let defaultModelDirectory = "Models/EEGEncoder"

    /// Hard cap on the IN-PROCESS estimator load (which runs only after the
    /// subprocess probe has already succeeded). A real load is ~0.1s; if it
    /// exceeds this it has hung, and we abandon it for the stub so app startup
    /// can never wedge. Overridable via `NEURALCOMPOSE_SPECTRAL_LOAD_TIMEOUT`.
    private static var inProcessLoadTimeoutSeconds: Double {
        if let raw = ProcessInfo.processInfo.environment["NEURALCOMPOSE_SPECTRAL_LOAD_TIMEOUT"],
           let v = Double(raw), v > 0 { return v }
        return 12.0
    }

    private enum SpectralLoadResult: Sendable {
        case loaded(any SpectralStateEstimating)
        case failed(String)
    }

    public struct Resolved: Sendable {
        public let estimator: any SpectralStateEstimating
        public let kind: Kind
        public let warning: String?

        public init(estimator: any SpectralStateEstimating, kind: Kind, warning: String?) {
            self.estimator = estimator
            self.kind = kind
            self.warning = warning
        }
    }

    public static func live(
        modelDirectory: URL? = nil,
        sentenceEmbedder: any SentenceEmbedder
    ) async -> Resolved {
        let chosenDir = modelDirectory ?? resolveDefaultDirectory()

        guard FileManager.default.fileExists(atPath: chosenDir.path) else {
            return stubResolved(warning: nil)
        }

        // Same crash-safety rationale as PredictorFactory: a failed
        // in-process MLX/Metal load can abort the whole process before any
        // `do/catch` around the real load ever runs, regardless of how
        // small the model is. Probe via a disposable child process first.
        switch await runInitProbeSubprocess(modelDirectory: chosenDir) {
        case .success(let metrics):
            BCILog.spectral.notice("""
                Spectral probe succeeded: modelLoad=\(metrics.modelLoadTime, privacy: .public)s \
                forwardPass=\(metrics.forwardPassLatency, privacy: .public)s \
                outputL2Norm=\(metrics.outputL2Norm, privacy: .public)
                """)
            // The probe proved MLX loads in a FRESH process, but the IN-PROCESS
            // load here has been observed to hang indefinitely in some runtime
            // contexts (a Metal/MLX stall the disposable probe can't reproduce —
            // it loaded fine at ~0.1s in the child). Race it against a timeout and
            // ABANDON it on hang, so a wedged load can never wedge makeDefault() /
            // app startup: we fall back to the stub, and the health watchdog then
            // surfaces estimatorKind=stub.
            let outcome: SpectralLoadResult? = await withAbandoningTimeout(
                seconds: inProcessLoadTimeoutSeconds
            ) {
                do {
                    let est = try await SpectralStateEstimator(
                        modelDirectory: chosenDir, sentenceEmbedder: sentenceEmbedder)
                    return .loaded(est)
                } catch {
                    return .failed((error as? BCIError)?.description ?? error.localizedDescription)
                }
            }
            switch outcome {
            case .loaded(let estimator):
                return Resolved(estimator: estimator, kind: .mlx, warning: nil)
            case .failed(let reason):
                BCILog.spectral.notice("Spectral estimator init failed after a successful probe (\(reason, privacy: .public)); using stub")
                return stubResolved(warning: "Spectral encoder present but failed to load: \(reason)")
            case .none:
                BCILog.spectral.notice("Spectral estimator in-process load exceeded \(inProcessLoadTimeoutSeconds, privacy: .public)s after a successful probe — abandoned the hung load; using stub")
                return stubResolved(warning: "Spectral encoder load hung in-process past the timeout; using stub estimator (see health.json).")
            }
        case .timeout:
            BCILog.spectral.notice("Spectral probe timed out for \(chosenDir.path, privacy: .public); using stub")
            return stubResolved(warning: "Spectral probe timed out; using stub estimator.")
        case .crashed(let signal):
            BCILog.spectral.notice("Spectral probe crashed (signal \(signal, privacy: .public)) for \(chosenDir.path, privacy: .public); using stub")
            return stubResolved(warning: "Spectral probe crashed (signal \(signal)); using stub estimator.")
        case .failed(let reason):
            BCILog.spectral.notice("Spectral probe failed (\(reason, privacy: .public)) for \(chosenDir.path, privacy: .public); using stub")
            return stubResolved(warning: "Spectral probe failed: \(reason)")
        }
    }

    private static func stubResolved(warning: String?) -> Resolved {
        Resolved(estimator: StubSpectralStateEstimator(), kind: .stub, warning: warning)
    }

    /// Spawns the standalone `SpectralProbe` binary (`--json <modelDirectory>`)
    /// as a disposable child process via the shared `SubprocessProbe`
    /// mechanism.
    private static func runInitProbeSubprocess(
        modelDirectory: URL, timeoutSeconds: Double = 20.0
    ) async -> SpectralProbeResult {
        guard let probeBinary = SubprocessProbe.locateSiblingBinary(named: "SpectralProbe") else {
            return .failed(reason: "SpectralProbe binary not found alongside the app executable")
        }
        return await SubprocessProbe.run(
            binary: probeBinary,
            arguments: ["--json", modelDirectory.path],
            timeoutSeconds: timeoutSeconds
        )
    }

    private static func resolveDefaultDirectory() -> URL {
        let env = ProcessInfo.processInfo.environment["NEURALCOMPOSE_SPECTRAL_MODEL"]
        if let env, !env.isEmpty {
            if env.hasPrefix("/") {
                return URL(fileURLWithPath: env)
            }
            return URL(fileURLWithPath: "Models").appendingPathComponent(env)
        }
        return URL(fileURLWithPath: defaultModelDirectory)
    }
}
