import Foundation

/// Resolves the `claude` CLI to an actual executable, or fails with a typed
/// error *before* any `Process` is launched.
///
/// The defect this replaces: the previous resolver returned the first
/// executable file from `["/usr/bin/env", "/usr/local/bin/claude",
/// "/opt/homebrew/bin/claude"]`. `/usr/bin/env` always exists and is always
/// executable, so it always won. That path was then handed to
/// `ClaudeCLITransport` as `executablePath`, whose override branch runs the
/// binary with the Claude argv *unmodified* — producing
/// `/usr/bin/env -p --model … `, i.e. `env: illegal option -- p`.
///
/// The original intent is visible in the old doc comment: the candidate list
/// was meant to answer "is Claude installed?" for a dry-run report, not to
/// name the executable. Conflating those two questions is what broke the
/// default harness runtime.
///
/// The rule here is deliberately narrow: **the resolved file must itself be
/// named `claude`.** A wrapper such as `env` needs an extra subcommand
/// argument that the argv contract does not carry, so accepting one can only
/// produce a malformed invocation.
public enum ClaudeExecutableResolver {

    public enum ResolutionError: Error, Equatable, CustomStringConvertible {
        /// An explicitly configured path does not exist.
        case explicitPathMissing(String)
        /// The path exists but is a directory.
        case notAFile(String)
        /// The path exists and is a file but is not executable.
        case notExecutable(String)
        /// The path is executable but is not named `claude` — e.g. `env`.
        /// Accepting it would require an unrecorded subcommand argument.
        case notClaude(path: String, basename: String)
        /// No `claude` was found on `PATH`.
        case notFoundOnPath(searched: [String])

        public var description: String {
            switch self {
            case .explicitPathMissing(let p):
                return "ClaudeExecutableResolver: configured path does not exist: \(p)"
            case .notAFile(let p):
                return "ClaudeExecutableResolver: not a file: \(p)"
            case .notExecutable(let p):
                return "ClaudeExecutableResolver: not executable: \(p)"
            case .notClaude(let p, let base):
                return "ClaudeExecutableResolver: refusing to run '\(base)' as the Claude CLI (\(p)). "
                    + "The executable must be named 'claude'; a wrapper would need a subcommand "
                    + "argument the Claude argv contract does not carry."
            case .notFoundOnPath(let searched):
                return "ClaudeExecutableResolver: no 'claude' executable on PATH. Searched: "
                    + (searched.isEmpty ? "<empty PATH>" : searched.joined(separator: ", "))
            }
        }
    }

    /// The name the resolved executable must have.
    public static let executableName = "claude"

    /// Resolves an absolute path to the `claude` binary.
    ///
    /// - Parameters:
    ///   - explicitPath: an operator-configured absolute path. When supplied it
    ///     is used exclusively — no PATH fallback, so a misconfiguration is a
    ///     hard error rather than a silent substitution.
    ///   - environment: the environment supplying `PATH`. Injected for tests.
    ///   - fileManager: injected for tests.
    public static func resolve(
        explicitPath: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) throws -> String {
        if let explicitPath {
            // An empty configured value is a misconfiguration, and falling back
            // to PATH here would be exactly the silent substitution this type
            // exists to prevent.
            guard !explicitPath.isEmpty else {
                throw ResolutionError.explicitPathMissing("<empty configured path>")
            }
            try validate(explicitPath, fileManager: fileManager)
            return explicitPath
        }

        let searched = searchPaths(in: environment)
        for directory in searched {
            let candidate = URL(fileURLWithPath: directory)
                .appendingPathComponent(executableName)
                .path
            guard fileManager.fileExists(atPath: candidate) else { continue }
            // A PATH entry holding a non-executable or misnamed file is skipped
            // rather than fatal — the next entry may hold a real one, which is
            // how PATH resolution is expected to behave.
            guard (try? validate(candidate, fileManager: fileManager)) != nil else { continue }
            return candidate
        }
        throw ResolutionError.notFoundOnPath(searched: searched)
    }

    /// Whether a path is an acceptable Claude executable. Used by
    /// `ClaudeCLITransport` as a last check before `Process.run()`.
    public static func validate(
        _ path: String,
        fileManager: FileManager = .default
    ) throws {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory) else {
            throw ResolutionError.explicitPathMissing(path)
        }
        guard !isDirectory.boolValue else {
            throw ResolutionError.notAFile(path)
        }
        guard fileManager.isExecutableFile(atPath: path) else {
            throw ResolutionError.notExecutable(path)
        }
        let basename = URL(fileURLWithPath: path).lastPathComponent
        guard basename == executableName else {
            throw ResolutionError.notClaude(path: path, basename: basename)
        }
    }

    /// `PATH` split on `:`, empty entries dropped, order preserved.
    static func searchPaths(in environment: [String: String]) -> [String] {
        guard let path = environment["PATH"], !path.isEmpty else { return [] }
        return path.split(separator: ":", omittingEmptySubsequences: true).map(String.init)
    }
}
