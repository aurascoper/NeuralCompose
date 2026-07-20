import BCICore
import Foundation

/// A `TextGenerating` conformer that drives a Claude model through the local
/// `claude` CLI in headless mode (`claude -p`), authenticated by the user's
/// Claude subscription — **no API key, no HTTP client**.
///
/// ⚠️ NETWORK EGRESS. This is the single deliberate exception to the project's
/// "No network at runtime" invariant (see `decision_registry.md` entry 8): the
/// composed prompt text is sent off-device to Anthropic by the CLI subprocess.
/// It is quarantined in `BCICloudBridge` (never `BCILLM`, which the boundary
/// contract keeps on-device), used only by the opt-in Stage-5 hypnagogic loop,
/// and only the prompt *text* leaves the machine — never audio (STT is
/// on-device) and never persisted.
///
/// `maxTokens` / `temperature` are not exposed by `claude -p`; response length
/// and tone are constrained by the system prompt instead.
public actor ClaudeCLIGenerator: TextGenerating {
    public nonisolated let isLive = true
    public nonisolated let modelIdentifier: String

    /// Constrained hypnagogic-mirror system prompt: passive, no questions, ≤2
    /// soft sentences. Kept here as the default so callers can't accidentally
    /// point this network path at an unconstrained prompt.
    public static let hypnagogicSystemPrompt = """
    You are a passive, resonant mirror for a user in a hypnagogic (N1, \
    sleep-onset) state. Your only job is to keep them gently suspended in \
    dream-logic without waking them.

    CONSTRAINTS:
    1. NEVER ask questions or request clarification.
    2. Accept any fragmented, bizarre, or nonsensical input as real; never \
    point out logical gaps or analyze it.
    3. Reply in at most TWO short, rhythmic sentences.
    4. Favor soft, sinking imagery (drifting, dissolving, floating, warm, dim, \
    slow); never sharp, urgent, or alarming content.
    5. Simply mirror and gently expand the imagery.
    Output only the spoken words — no preamble, no explanation, no quotes.
    """

    /// Constrained WAKING dialectical system prompt: lucid and present, NOT the
    /// N1 sleep-mirror above. Used for the Focused / Reflective / Contemplative
    /// profiles, where the point is a coherent exchange, not sleep onset. Each
    /// turn the loop asks two voices with opposing objectives to speak; this
    /// frame keeps each voice clear and concise while it *holds* the tension
    /// rather than resolving it. This is the user's knob — the literal voice the
    /// app speaks — so edit it to taste (cf. `DialecticalField.target()`).
    public static let wakingDialecticalSystemPrompt = """
    You are one voice in a live, waking dialectical exchange. Another voice is \
    pulling the opposite way; your job is not to agree with it or defeat it, but \
    to hold your own line clearly so the tension between you stays alive.

    CONSTRAINTS:
    1. Stay lucid, present, and coherent — this is waking dialogue, not \
    dream-logic. No drifting, dissolving, or sleep imagery.
    2. Take a clear position and develop it; do not hedge to the middle or \
    prematurely reconcile with the other voice.
    3. Speak in at most THREE sentences. Be substantive, never padded.
    4. You may build on, push against, or reframe what you heard — but never ask \
    the user a question or request clarification.
    5. Plain, direct language. No preamble, no meta-commentary, no stage \
    directions.
    Output only the spoken words.
    """

    private let model: String
    private let systemPrompt: String
    private let executableOverride: String?

    public init(
        model: String = "claude-sonnet-5",
        systemPrompt: String = ClaudeCLIGenerator.hypnagogicSystemPrompt,
        executablePath: String? = nil
    ) {
        self.model = model
        self.systemPrompt = systemPrompt
        self.executableOverride = executablePath
        self.modelIdentifier = "\(model) (claude-cli)"
    }

    public func generate(
        prompt: String,
        maxTokens: Int,
        temperature: Double,
        cancellationID: UUID
    ) async throws -> String {
        try Task.checkCancellation()
        let args = [
            "-p",
            "--model", model,
            "--system-prompt", systemPrompt,
            "--output-format", "json",
            prompt,
        ]
        let data = try await runClaude(args)
        return try Self.parseResult(data)
    }

    private func runClaude(_ args: [String]) async throws -> Data {
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
    /// Pure (no subprocess) so it is unit-testable.
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
/// same pattern as the delegate proxies elsewhere in the codebase.
private final class CLIInvocation: @unchecked Sendable {
    let process = Process()
    let stdout = Pipe()
}
