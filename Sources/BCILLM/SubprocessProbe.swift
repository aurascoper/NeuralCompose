import Foundation

/// Generic disposable-subprocess probe mechanism, extracted from
/// `PredictorFactory`'s original `runInitProbeSubprocess`/`locateMLXProbeBinary`
/// so a second MLX-backed factory (the spectral state estimator) can reuse
/// the exact same safety-critical machinery instead of a hand-copied
/// duplicate that could silently drift.
///
/// Exists because a failed in-process MLX/Metal load can abort the whole
/// process in a way Swift can't catch — before any `do/catch` around the
/// real load ever gets a chance to run. Model size doesn't change this risk:
/// a small conv-net's first `eval()` can abort the process exactly like an
/// LLM's can. So any MLX-backed factory in this app probes via a disposable
/// child process first, and falls back to a stub if the probe doesn't
/// cleanly succeed.
public enum SubprocessProbe {

    /// `.success`/`.failed` are the only two cases a probe can observe about
    /// *itself* — a process can't detect its own timeout-by-parent or its
    /// own uncaught-signal crash. `.timeout` and `.crashed` only ever get
    /// constructed by whichever process is *supervising* a probe subprocess,
    /// by interpreting how that child process actually terminated.
    public enum Outcome<T: Sendable & Codable & Equatable>: Sendable, Codable, Equatable {
        case success(T)
        case failed(reason: String)
        case timeout
        case crashed(signal: Int32)
    }

    /// Guards against resuming the probe's continuation twice: the
    /// termination handler and the timeout task both race to resolve it,
    /// and only the first should count. Generic over the same `T` as
    /// `Outcome<T>` — Swift doesn't allow a type to be nested directly
    /// inside a generic function, so this lives at the enum level instead.
    private final class ResumeOnce<T: Sendable & Codable & Equatable>: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func resume(_ continuation: CheckedContinuation<Outcome<T>, Never>, _ value: Outcome<T>) {
            lock.lock()
            defer { lock.unlock() }
            guard !done else { return }
            done = true
            continuation.resume(returning: value)
        }
    }

    /// Spawns `binary` with `arguments` as a disposable child process and
    /// races it against `timeoutSeconds`, returning an `Outcome` that
    /// distinguishes success, a parseable failure, a timeout, and a
    /// crash-by-signal. The child is expected to write exactly one JSON
    /// line (decodable as `Outcome<T>`) to stdout and nothing else, so
    /// reading the whole pipe after the process exits (inside
    /// `terminationHandler`) is safe without a streaming reader — the
    /// payload is always small.
    ///
    /// The timeout matters independently of the crash risk this mechanism
    /// exists for: model loading can also hang rather than crash — with no
    /// timeout, a hung probe would block the entire app's startup forever
    /// instead of just falling back to a stub.
    public static func run<T: Sendable & Codable & Equatable>(
        binary: URL, arguments: [String], timeoutSeconds: Double
    ) async -> Outcome<T> {
        let process = Process()
        process.executableURL = binary
        process.arguments = arguments
        let stdoutPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = FileHandle.nullDevice

        return await withCheckedContinuation { continuation in
            let once = ResumeOnce<T>()
            process.terminationHandler = { p in
                if p.terminationReason == .uncaughtSignal {
                    once.resume(continuation, .crashed(signal: p.terminationStatus))
                    return
                }
                let data = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                guard let decoded = try? JSONDecoder().decode(Outcome<T>.self, from: data) else {
                    once.resume(continuation, .failed(
                        reason: "probe exited with status \(p.terminationStatus), no parseable output"
                    ))
                    return
                }
                once.resume(continuation, decoded)
            }
            do {
                try process.run()
            } catch {
                once.resume(continuation, .failed(reason: "failed to launch \(binary.lastPathComponent): \(error.localizedDescription)"))
                return
            }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                guard process.isRunning else { return }
                process.terminate()
                once.resume(continuation, .timeout)
            }
        }
    }

    /// Looks for a probe binary named `name` next to the app's own
    /// executable — true for `swift build`/`swift run`/Xcode SwiftPM-scheme
    /// builds (the only ways this app is currently launched; both put
    /// sibling executables in the same build-products directory). A real
    /// distributable `.app` bundling probe binaries as helper tools is
    /// future work, not handled here — `nil` in that case, same as any
    /// other probe-unavailable path.
    public static func locateSiblingBinary(named name: String) -> URL? {
        guard let executablePath = CommandLine.arguments.first else { return nil }
        let sibling = URL(fileURLWithPath: executablePath)
            .deletingLastPathComponent()
            .appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: sibling.path) ? sibling : nil
    }
}
