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

    /// Set (to the model directory path) in the environment of the probe
    /// subprocess `live(modelDirectory:)` spawns before it ever touches MLX
    /// in-process. See `runProbeIfRequested()`'s doc comment for why this
    /// exists.
    public static let probeDirEnvVar = "NEURALCOMPOSE_MLX_PROBE_DIR"

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

        // MLX's C++/Metal layer can fail to load its default metallib in a
        // way that is NOT a catchable Swift `Error` — it aborts the whole
        // process before `MLXNextWordPredictor.init`'s own `do/catch` ever
        // gets a chance to run (confirmed empirically: a plain `swift run`/
        // `swift test` invocation crashes with "MLX error: Failed to load
        // the default metallib" the instant any MLX API is touched, in an
        // environment where mlx-swift's Metal shaders weren't bundled next
        // to a bare SwiftPM-built binary the way they would be in an
        // Xcode-built .app — see MODEL_SETUP.md). Prediction is optional;
        // the application launching is not. So the real load is only
        // attempted in-process after a disposable child-process probe
        // (re-running this same executable) has already survived it — if
        // the probe crashes, so would we, and we fall back to the stub
        // instead.
        guard await runProbeSubprocess(modelDirectory: dir) else {
            BCILog.predictor.notice("MLX probe subprocess failed or crashed for \(dir.path, privacy: .public); using stub")
            let stub = StubNextWordPredictor()
            return Resolved(
                predictor: stub,
                embeddingProvider: stub,
                generator: stub,
                tokenizer: tokenizer,
                kind: .stub,
                warning: "MLX unavailable in this environment (Metal library failed to load) — using stub predictor"
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

    /// If this process was launched as an MLX probe (see `live(modelDirectory:)`'s
    /// doc comment), attempts the real MLX load and **terminates the
    /// process** with exit code 0 (success) or 1 (a catchable failure) —
    /// never returns in that case. A native crash here just crashes this
    /// disposable child process, which is exactly the point: the parent
    /// (the real app) observes a non-zero/signal exit and falls back to
    /// the stub instead of dying itself.
    ///
    /// Call this once, as early as possible in the app's entry point,
    /// before any other startup work — see `NeuralComposeAppEntry.init()`.
    /// Returns normally (a no-op) when the probe env var isn't set, i.e.
    /// for every regular app launch.
    public static func runProbeIfRequested() async -> Never? {
        guard let dir = ProcessInfo.processInfo.environment[probeDirEnvVar], !dir.isEmpty else {
            return nil
        }
        do {
            _ = try await MLXNextWordPredictor(modelDirectory: URL(fileURLWithPath: dir))
            exit(0)
        } catch {
            exit(1)
        }
    }

    /// Re-invokes this same executable with `probeDirEnvVar` set, and
    /// waits for it to exit. `true` only on a clean exit(0); `false` on
    /// any non-zero exit, a crash/signal, *or* a timeout.
    ///
    /// The timeout matters independently of the crash risk this whole
    /// mechanism exists for: MLX model loading can also hang rather than
    /// crash (observed: a tokenizer-config resolution step that made a
    /// network call and never returned on a restricted connection) — with
    /// no timeout, a hung probe would block the entire app's startup
    /// forever instead of just falling back to the stub.
    private static func runProbeSubprocess(
        modelDirectory: URL, timeoutSeconds: Double = 20.0
    ) async -> Bool {
        guard let executablePath = CommandLine.arguments.first else { return false }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        var env = ProcessInfo.processInfo.environment
        env[probeDirEnvVar] = modelDirectory.path
        process.environment = env
        // The probe never touches stdin/stdout meaningfully; discard both
        // so a crash's stderr diagnostic doesn't get tangled with the
        // parent app's own output.
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        // Guards against resuming the continuation twice: the
        // termination handler and the timeout task both race to resolve
        // it, and only the first should count.
        final class ResumeOnce: @unchecked Sendable {
            private let lock = NSLock()
            private var done = false
            func resume(_ continuation: CheckedContinuation<Bool, Never>, _ value: Bool) {
                lock.lock()
                defer { lock.unlock() }
                guard !done else { return }
                done = true
                continuation.resume(returning: value)
            }
        }

        return await withCheckedContinuation { continuation in
            let once = ResumeOnce()
            process.terminationHandler = { p in
                once.resume(continuation, p.terminationStatus == 0)
            }
            do {
                try process.run()
            } catch {
                once.resume(continuation, false)
                return
            }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                guard process.isRunning else { return }
                BCILog.predictor.notice("MLX probe subprocess exceeded \(timeoutSeconds, format: .fixed(precision: 0))s; terminating and using stub")
                process.terminate()
                once.resume(continuation, false)
            }
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
