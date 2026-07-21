import BCICore
import Foundation

/// `ClaudeCLITransport` is a `GenerationTransport` that drives a
/// Claude model through the local `claude` CLI in headless mode
/// (`claude -p`), authenticated by the user's Claude subscription —
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
/// machine — never audio (STT is on-device) and never persisted.
///
/// `maxTokens` / `temperature` are not exposed by `claude -p`;
/// response length and tone are constrained by the system prompt
/// instead. The transport therefore passes the system prompt
/// verbatim and ignores `temperature` / `maxTokens` on the
/// `GenerationTransportRequest` — the keep-bar requires
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

    private static func runClaude(
        args: [String],
        executableOverride: String?
    ) async throws -> Data {
        let inv = CLIInvocation()
        if let override = executableOverride {
            inv.process.executableURL = URL(fileURLWithPath: override)
            inv.process.arguments = args
        } else {
            // Resolve `claude` from PATH without hardcoding a location.
            inv.process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            inv.process.arguments = ["claude"] + args
        }
        inv.process.standardOutput = inv.stdout
        // Discard stderr so a chatty CLI can't fill a pipe buffer and stall exit.
        inv.process.standardError = FileHandle.nullDevice

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, any Error>) in
                inv.process.terminationHandler = { proc in
                    let out = inv.stdout.fileHandleForReading.readDataToEndOfFile()
                    if proc.terminationStatus == 0 {
                        cont.resume(returning: out)
                    } else {
                        cont.resume(throwing: BCIError.predictorInferenceFailed(
                            reason: "claude CLI exited with status \(proc.terminationStatus)"))
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

    /// Parse the `claude -p --output-format json` envelope into the result text.
    /// Pure (no subprocess) so it is unit-testable. Same parser as
    /// `ClaudeCLIGenerator.parseResult(_:)` — the new code path is
    /// byte-equivalent.
    public static func parseResult(_ data: Data) throws -> String {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BCIError.predictorInferenceFailed(reason: "claude CLI returned non-JSON output")
        }
        if let isError = obj["is_error"] as? Bool, isError {
            throw BCIError.predictorInferenceFailed(reason: "claude CLI reported an error")
        }
        guard let result = obj["result"] as? String else {
            throw BCIError.predictorInferenceFailed(reason: "claude CLI JSON missing 'result' field")
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Holds the non-`Sendable` `Process`/`Pipe` so the run body, termination
/// handler, and cancellation handler can all reference the same invocation
/// under strict concurrency. Access is effectively serialized (configure →
/// run once → terminate/terminationHandler), so `@unchecked` is justified —
/// same pattern as `CLIInvocation` in `ClaudeCLIGenerator.swift`.
private final class CLIInvocation: @unchecked Sendable {
    let process = Process()
    let stdout = Pipe()
}
