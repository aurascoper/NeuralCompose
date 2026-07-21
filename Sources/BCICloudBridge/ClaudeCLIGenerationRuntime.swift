import BCICore
import Foundation

/// `ClaudeCLIGenerationRuntime` is the `GenerationRuntime` conformer
/// for the `claude -p` path. It composes a `ClaudeCLITransport` and a
/// `PromptProfile` and produces a `GenerationResult` with a fully
/// populated `GenerationMetadata` (which the telemetry
/// `GeneratorFingerprint` derives from).
///
/// This runtime is the byte-equivalent of the legacy `TextGenerating`
/// path through `ClaudeCLIGenerator`:
///   - same subprocess invocation (`claude -p --model <m> --system-prompt <s>
///     --output-format json <prompt>`),
///   - same JSON parser (`ClaudeCLITransport.parseResult`),
///   - same system-prompt bytes (the `PromptProfile` is loaded from
///     the same Markdown file the legacy `static let` was loaded
///     from).
///
/// What it adds is the typed `GenerationResult` / `GenerationMetadata`
/// surface, the `RuntimeCapabilities` advertisement, and the
/// `runtime / transport / provider / model / prompt_hash` fingerprint
/// the seed-004 telemetry requires.
///
/// Legacy `TextGenerating` call sites are not affected by this
/// runtime's existence: they continue to use `ClaudeCLIGenerator`
/// (which preserves the legacy `static let` API surface). A future
/// commit migrates those call sites incrementally.
public struct ClaudeCLIGenerationRuntime: GenerationRuntime {
    public let runtimeName = "claude-cli"
    public let modelIdentifier: String
    public let isLive = true
    public let capabilities = RuntimeCapabilities() // token counting / streaming / logProbs not exposed by `claude -p`

    private let model: String
    private let promptProfile: PromptProfile
    private let systemPrompt: String
    private let transport: ClaudeCLITransport
    private let interactionStyle: String
    private let executableOverride: String?

    public init(
        model: String = "claude-sonnet-5",
        promptProfile: PromptProfile,
        interactionStyle: String = "dialectical",
        executablePath: String? = nil
    ) {
        self.model = model
        self.promptProfile = promptProfile
        self.interactionStyle = interactionStyle
        self.executableOverride = executablePath
        self.modelIdentifier = "\(model) (claude-cli)"
        self.systemPrompt = (try? promptProfile.load()) ?? ""
        self.transport = ClaudeCLITransport(model: model, executablePath: executablePath)
    }

    public init(
        model: String = "claude-sonnet-5",
        systemPrompt: String,
        interactionStyle: String = "dialectical",
        executablePath: String? = nil
    ) {
        self.model = model
        self.systemPrompt = systemPrompt
        self.interactionStyle = interactionStyle
        self.executableOverride = executablePath
        self.modelIdentifier = "\(model) (claude-cli)"
        // System-prompt-override path: the caller owns the prompt
        // text (legacy `TextGenerating` callers do this). The
        // `PromptProfile` is a synthetic `.wakingDialectical` for
        // prompt-hash bookkeeping; the bytes the transport sees are
        // the caller's `systemPrompt`, NOT the loaded profile. This
        // is the keep-bar: text-equivalence with the legacy path.
        self.promptProfile = .wakingDialectical
        self.transport = ClaudeCLITransport(model: model, executablePath: executablePath)
    }

    public func generate(
        prompt: String,
        context: GenerationContext
    ) async throws -> GenerationResult {
        try Task.checkCancellation()
        let started = Date()
        let request = GenerationTransportRequest(
            model: model,
            prompt: prompt,
            systemPrompt: systemPrompt,
            temperature: context.generationParameters.temperature,
            maxTokens: context.generationParameters.maxTokens
        )
        let response = try await transport.send(request)
        let elapsed = Int(Date().timeIntervalSince(started) * 1000)
        let promptHash = (try? promptProfile.hash()) ?? ""
        let metadata = GenerationMetadata(
            runtime: runtimeName,
            transport: transport.transportName,
            provider: transport.providerName,
            model: model,
            promptHash: promptHash,
            promptProfile: promptProfile.rawValue,
            interactionStyle: interactionStyle,
            generationParameters: Self.flatParameters(context.generationParameters),
            latencyMilliseconds: elapsed,
            tokenCount: nil
        )
        return GenerationResult(text: response.text, metadata: metadata)
    }

    private static func flatParameters(
        _ p: GenerationContext.GenerationParameters
    ) -> [String: Double] {
        var out: [String: Double] = [:]
        if let t = p.temperature { out["temperature"] = t }
        if let m = p.maxTokens { out["max_tokens"] = Double(m) }
        return out
    }
}
