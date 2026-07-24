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
    ///
    /// The text is loaded from `Sources/BCICloudBridge/Prompts/hypnagogic.md`
    /// (ADR-009 invariant #1: prompt profiles are repository resources, not
    /// code on the runtime). The Markdown file is the source of truth; this
    /// computed property is a load-by-name convenience for the legacy
    /// `static let` call sites. The loaded text is byte-identical to the
    /// pre-extraction value.
    /// Throws rather than yielding `""`. An empty value here would be sent as
    /// `claude -p --system-prompt ""` — an unconstrained model on the one
    /// deliberate network-egress path — which is precisely what the "callers
    /// can't accidentally point this at an unconstrained prompt" guarantee
    /// above is supposed to prevent.
    public static func hypnagogicSystemPrompt() throws -> String {
        try PromptProfile.hypnagogic.load()
    }

    /// Constrained WAKING dialectical system prompt: lucid and present, NOT the
    /// N1 sleep-mirror above. Used for the Focused / Reflective / Contemplative
    /// profiles, where the point is a coherent exchange, not sleep onset. Each
    /// turn the loop asks two voices with opposing objectives to speak; this
    /// frame keeps each voice clear and concise while it *holds* the tension
    /// rather than resolving it. This is the user's knob — the literal voice the
    /// app speaks — so edit it to taste (cf. `DialecticalField.target()`).
    ///
    /// Source: `Sources/BCICloudBridge/Prompts/waking-dialectical.md`.
    public static func wakingDialecticalSystemPrompt() throws -> String {
        try PromptProfile.wakingDialectical.load()
    }

    /// The Witness's system prompt — a NON-VOICED introspective observer for the
    /// Reflective profile (see `Sources/BCICore/Dialectic/WITNESS.md`). Unlike the
    /// two poles, it is *permitted* meta-commentary (it deliberately relaxes
    /// constraint #5 of `wakingDialecticalSystemPrompt`), because its whole job is
    /// to name what the exchange avoided. Its output is NEVER spoken aloud and
    /// NEVER heard by the poles or the user — it only feeds telemetry/prosody, so
    /// the poles cannot learn to satisfy it. Waking register (no sleep imagery —
    /// this ships on a waking rung).
    ///
    /// Source: `Sources/BCICloudBridge/Prompts/witness.md`.
    public static func witnessSystemPrompt() throws -> String {
        try PromptProfile.witness.load()
    }

    private let model: String
    private let systemPrompt: String
    private let executableOverride: String?

    /// `systemPrompt: nil` loads the hypnagogic profile. Throws if the prompt
    /// resource is unavailable or empty, so a packaging failure disables this
    /// path instead of silently sending an unconstrained prompt.
    ///
    /// This cannot be a defaulted argument, because a default expression
    /// cannot throw — which is exactly how the empty-string fallback got
    /// introduced in the first place.
    public init(
        model: String = "claude-sonnet-5",
        systemPrompt: String? = nil,
        executablePath: String? = nil
    ) throws {
        let resolved = try systemPrompt ?? PromptProfile.hypnagogic.load()
        guard !resolved.isEmpty else {
            throw PromptProfileError.emptyResource("<caller-supplied system prompt>")
        }
        self.model = model
        self.systemPrompt = resolved
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
