import BCICore
import Foundation

/// `ClaudeCLITransport` is a `GenerationTransport` that drives a
/// Claude model through the local `claude` CLI in headless mode
/// (`claude -p`), authenticated by the user's Claude subscription -
/// **no API key, no HTTP client**.
///
/// The transport wraps the exact subprocess invocation the legacy
/// `ClaudeCLIGenerator.runClaude(...)` path uses; behavior is
/// preserved byte-for-byte. `ClaudeCLIGenerationRuntime` composes
/// this transport + a `PromptProfile` to produce a `GenerationRuntime`
/// conformer.
///
/// ⚠️ NETWORK EGRESS. This is the single deliberate exception to the
/// project's "No network at runtime" invariant (see
/// `decision_registry.md` entry 8): the composed prompt text is sent
/// off-device to Anthropic by the CLI subprocess. It is quarantined
/// in `BCICloudBridge` (never `BCILLM`), used only by the opt-in
/// Stage-5 dialectic loop, and only the prompt *text* leaves the
/// machine - never audio (STT is on-device) and never persisted.
///
/// `maxTokens` / `temperature` are not exposed by `claude -p`;
/// response length and tone are constrained by the system prompt
/// instead. The transport therefore passes the system prompt
/// verbatim and ignores `temperature` / `maxTokens` on the
/// `GenerationTransportRequest` - the keep-bar requires
/// `TextGenerating` and `GenerationRuntime` to produce identical
/// output for the same prompt, and the legacy path already passes
/// the request as `claude -p` does.
public struct ClaudeCLITransport: GenerationTransport {
    public let transportName = "claude-cli"
    public let providerName = "anthropic"

    private let model: String
    private let executableOverride: String?

    public init(
        model: String = "claude-sonnet-5",
        executablePath: String? = nil
    ) {
        self.model = model
        self.executableOverride = executablePath
    }

    public func send(_ request: GenerationTransportRequest) async throws -> GenerationTransportResponse {
        let args = Self.buildArgs(
            model: model,
            systemPrompt: request.systemPrompt,
            prompt: request.prompt
        )
        let data = try await Self.runClaude(
            args: args,
            executableOverride: executableOverride
        )
        let text = try Self.parseResult(data)
        return GenerationTransportResponse(
            text: text,
            rawMetadata: ["transport": transportName, "provider": providerName, "model": model],
            finishReason: .endTurn
        )
    }

    /// The exact `claude -p` argument vector. Static + pure so it is
    /// unit-testable without a subprocess.
    public static func buildArgs(
        model: String,
        systemPrompt: String,
        prompt: String
    ) -> [String] {
        [
            "-p",
            "--model", model,
            "--system-prompt", systemPrompt,
            "--output-format", "json",
            prompt,
        ]
    }

    /// Resolve the `claude` executable and child environment even when the
    /// macOS `.app` bundle is launched by LaunchServices / Finder with a minimal
    /// `PATH=/usr/bin:/bin:/usr/sbin:/sbin` or when `~/.local/bin/claude` is a
    /// dangling symlink while `~/Library/Application Support/Claude/claude-code`
    /// contains a valid `claude.app/Contents/MacOS/claude` binary.
    public static func resolveExecutable(
        override: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> (executableURL: URL, argumentsPrefix: [String], environment: [String: String]) {
        var childEnv = environment
        childEnv.removeValue(forKey: "CLAUDECODE")
        childEnv.removeValue(forKey: "CLAUDE_CODE_ENTRYPOINT")

        let home = childEnv["HOME"] ?? FileManager.default.homeDirectoryForCurrentUser.path
        var extraDirs: [String] = [
            "\(home)/.local/bin",
        ]
        let claudeCodeRoot = "\(home)/Library/Application Support/Claude/claude-code"
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: claudeCodeRoot) {
            for ver in versions.sorted(by: { $0.compare($1, options: .numeric) == .orderedDescending }) {
                let macOSDir = "\(claudeCodeRoot)/\(ver)/claude.app/Contents/MacOS"
                extraDirs.append(macOSDir)
            }
        }
        let sdkCacheRoot = "\(home)/Library/Application Support/Code/agent-host/sdk-cache/claude"
        if let sdkVersions = try? FileManager.default.contentsOfDirectory(atPath: sdkCacheRoot) {
            for ver in sdkVersions.sorted(by: { $0.compare($1, options: .numeric) == .orderedDescending }) {
                let sdkDir = "\(sdkCacheRoot)/\(ver)/darwin-arm64/node_modules/@anthropic-ai/claude-agent-sdk-darwin-arm64"
                extraDirs.append(sdkDir)
            }
        }
        if let bundleBin = Bundle.main.resourceURL?.appendingPathComponent("equifinal_bin").path {
            extraDirs.append(bundleBin)
        }
        extraDirs.append(contentsOf: [
            "/opt/homebrew/bin",
            "/usr/local/bin",
        ])

        let existingPath = childEnv["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        let existingParts = existingPath.split(separator: ":").map(String.init)
        var mergedParts: [String] = []
        for dir in extraDirs + existingParts where !dir.isEmpty && !mergedParts.contains(dir) {
            mergedParts.append(dir)
        }
        childEnv["PATH"] = mergedParts.joined(separator: ":")

        if let override, !override.isEmpty {
            return (URL(fileURLWithPath: override), [], childEnv)
        }
        if let envBin = childEnv["NEURALCOMPOSE_CLAUDE_BIN"],
           !envBin.isEmpty {
            let resolvedEnvPath = URL(fileURLWithPath: envBin).resolvingSymlinksInPath().path
            if FileManager.default.isExecutableFile(atPath: envBin) &&
               FileManager.default.isExecutableFile(atPath: resolvedEnvPath) {
                return (URL(fileURLWithPath: envBin), [], childEnv)
            }
        }
        for dir in mergedParts {
            let candidateURL = URL(fileURLWithPath: dir).appendingPathComponent("claude")
            let candidate = candidateURL.path
            let resolvedTarget = candidateURL.resolvingSymlinksInPath().path
            if FileManager.default.isExecutableFile(atPath: candidate) &&
               FileManager.default.isExecutableFile(atPath: resolvedTarget) {
                return (candidateURL, [], childEnv)
            }
        }
        return (URL(fileURLWithPath: "/usr/bin/env"), ["claude"], childEnv)
    }

    private static func runClaude(
        args: [String],
        executableOverride: String?
    ) async throws -> Data {
        let inv = CLIInvocation()
        let resolved = Self.resolveExecutable(override: executableOverride)
        inv.process.executableURL = resolved.executableURL
        inv.process.arguments = resolved.argumentsPrefix + args
        inv.process.environment = resolved.environment
        inv.process.standardOutput = inv.stdout
        inv.process.standardError = inv.stderr

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, any Error>) in
                inv.process.terminationHandler = { proc in
                    let out = inv.stdout.fileHandleForReading.readDataToEndOfFile()
                    let errData = inv.stderr.fileHandleForReading.readDataToEndOfFile()
                    if proc.terminationStatus == 0 {
                        cont.resume(returning: out)
                    } else {
                        let snippet = Self.extractFailureDetail(stderr: errData, stdout: out)
                        let detail = snippet.isEmpty ? "" : ": \(String(snippet.prefix(240)))"
                        cont.resume(throwing: BCIError.predictorInferenceFailed(
                            reason: "claude CLI exited with status \(proc.terminationStatus)\(detail)"))
                    }
                }
                do {
                    try inv.process.run()
                } catch {
                    cont.resume(throwing: BCIError.predictorInferenceFailed(
                        reason: "could not launch the `claude` CLI (\(error.localizedDescription)); "
                              + "is it installed on PATH and signed in?"))
                }
            }
        } onCancel: {
            inv.process.terminate()
        }
    }

    public static func extractFailureDetail(stderr: Data, stdout: Data) -> String {
        let stderrText = (String(data: stderr, encoding: .utf8) ?? "")
            .replacingOccurrences(of: "\u{2014}", with: " - ")
            .replacingOccurrences(of: "\u{2013}", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !stderrText.isEmpty {
            return stderrText
        }
        if let obj = try? JSONSerialization.jsonObject(with: stdout) as? [String: Any] {
            if let resultText = (obj["result"] as? String) ?? (obj["error"] as? String) {
                let cleaned = resultText
                    .replacingOccurrences(of: "\u{2014}", with: " - ")
                    .replacingOccurrences(of: "\u{2013}", with: "-")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !cleaned.isEmpty {
                    return cleaned
                }
            }
        }
        return (String(data: stdout, encoding: .utf8) ?? "")
            .replacingOccurrences(of: "\u{2014}", with: " - ")
            .replacingOccurrences(of: "\u{2013}", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Parse the `claude -p --output-format json` envelope into the result text.
    /// Pure (no subprocess) so it is unit-testable. Same parser as
    /// `ClaudeCLIGenerator.parseResult(_:)` - the new code path is
    /// byte-equivalent.
    public static func parseResult(_ data: Data) throws -> String {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BCIError.predictorInferenceFailed(reason: "claude CLI returned non-JSON output")
        }
        if let isError = obj["is_error"] as? Bool, isError {
            let errMsg = ((obj["result"] as? String) ?? (obj["error"] as? String) ?? "")
                .replacingOccurrences(of: "\u{2014}", with: " - ")
                .replacingOccurrences(of: "\u{2013}", with: "-")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let detail = errMsg.isEmpty ? "" : ": \(String(errMsg.prefix(240)))"
            throw BCIError.predictorInferenceFailed(reason: "claude CLI reported an error\(detail)")
        }
        guard let result = obj["result"] as? String else {
            throw BCIError.predictorInferenceFailed(reason: "claude CLI JSON missing 'result' field")
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Holds the non-`Sendable` `Process`/`Pipe` so the run body, termination
/// handler, and cancellation handler can all reference the same invocation
/// under strict concurrency. Access is effectively serialized (configure ->
/// run once -> terminate/terminationHandler), so `@unchecked` is justified -
/// same pattern as `CLIInvocation` in `ClaudeCLIGenerator.swift`.
private final class CLIInvocation: @unchecked Sendable {
    let process = Process()
    let stdout = Pipe()
    let stderr = Pipe()
}
