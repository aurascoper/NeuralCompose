import BCICore
import Foundation

/// `OllamaGenerationRuntime` is the `GenerationRuntime` conformer for
/// the Ollama HTTP transport. It composes an `OllamaHTTPTransport`
/// and a `PromptProfile` and produces a `GenerationResult` with
/// the full `runtime / transport / provider / model / promptHash`
/// fingerprint.
///
/// ADR-009 invariant #3: a new model behind an existing transport
/// is a configuration change, not a Swift type. The runtime's
/// `modelIdentifier` carries the model name; the transport is the
/// type. Adding `qwen2.5:7b` to the supported-models list is
/// `OllamaGenerationRuntime(model: "qwen2.5:7b", promptProfile:
/// .wakingDialectical)` — no new Swift code.
///
/// ADR-009 invariant #2: the runtime MUST NOT modify semantic
/// intent. The prompt text and system prompt bytes are passed
/// verbatim to the transport; the transport concatenates them
/// with a documented delimiter (see `OllamaHTTPTransport.composePrompt`)
/// and forwards them to Ollama. The runtime does not rewrite,
/// summarize, or re-instruct.
///
/// Capabilities: Ollama's response envelope includes `eval_count`
/// (output token count) and `prompt_eval_count` (input token
/// count), so this runtime advertises `tokenCounting: true` and
/// publishes both as `GenerationMetadata` fields. This is the
/// keep-bar's "capability-advertised, not method-mandatory"
/// invariant (ADR-009 #4) in action: the Claude runtime returns
/// `nil` for token counts because `claude -p` does not expose
/// them; the Ollama runtime returns the values because it can.
public struct OllamaGenerationRuntime: GenerationRuntime {
    public let runtimeName = "ollama"
    public let modelIdentifier: String
    public let isLive = true
    public let capabilities: RuntimeCapabilities

    private let model: String
    private let promptProfileName: String
    private let systemPrompt: String
    private let promptHash: String
    private let transport: OllamaHTTPTransport
    private let interactionStyle: String

    /// Fails rather than constructing a runtime with no constraining prompt.
    /// `OllamaHTTPTransport.composePrompt` drops the delimiter entirely when
    /// the system prompt is empty, so the model would have received bare user
    /// text with no framing at all.
    public init(
        model: String,
        promptProfile: PromptProfile,
        interactionStyle: String = "dialectical",
        baseURL: URL = URL(string: "http://localhost:11434")!,
        session: URLSession = URLSession(configuration: .default)
    ) throws {
        let loaded = try promptProfile.load()
        self.model = model
        self.promptProfileName = promptProfile.rawValue
        self.interactionStyle = interactionStyle
        self.modelIdentifier = "\(model) (ollama)"
        self.systemPrompt = loaded
        self.promptHash = PromptProfile.sha256Hex(loaded)
        self.transport = OllamaHTTPTransport(baseURL: baseURL, session: session)
        // Ollama exposes token counts in its response envelope;
        // the Claude runtime does not. Capability advertising
        // (ADR-009 invariant #4) lets consumers query the
        // difference without special-casing.
        self.capabilities = RuntimeCapabilities(
            tokenCounting: true,
            streaming: false,
            logProbs: false
        )
    }

    /// System-prompt-override path. The profile name is `custom` and the hash
    /// covers the caller's bytes; it previously claimed `wakingDialectical`
    /// and hashed that profile regardless of what was actually sent.
    public init(
        model: String,
        systemPrompt: String,
        interactionStyle: String = "dialectical",
        baseURL: URL = URL(string: "http://localhost:11434")!,
        session: URLSession = URLSession(configuration: .default)
    ) throws {
        guard !systemPrompt.isEmpty else {
            throw PromptProfileError.emptyResource("<caller-supplied system prompt>")
        }
        self.model = model
        self.systemPrompt = systemPrompt
        self.promptHash = PromptProfile.sha256Hex(systemPrompt)
        self.interactionStyle = interactionStyle
        self.modelIdentifier = "\(model) (ollama)"
        self.promptProfileName = "custom"
        self.transport = OllamaHTTPTransport(baseURL: baseURL, session: session)
        self.capabilities = RuntimeCapabilities(
            tokenCounting: true,
            streaming: false,
            logProbs: false
        )
    }

    public func generate(
        prompt: String,
        context: GenerationContext
    ) async throws -> GenerationResult {
        try Task.checkCancellation()
        // Backstop at the last gate before the request leaves the process.
        guard !systemPrompt.isEmpty else {
            throw PromptProfileError.emptyResource("<system prompt at egress>")
        }
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
        let tokenCount: Int? = {
            if let s = response.rawMetadata["eval_count"], let v = Int(s) { return v }
            return nil
        }()
        let metadata = GenerationMetadata(
            runtime: runtimeName,
            transport: transport.transportName,
            provider: transport.providerName,
            model: model,
            promptHash: promptHash,
            promptProfile: promptProfileName,
            interactionStyle: interactionStyle,
            generationParameters: Self.flatParameters(context.generationParameters),
            latencyMilliseconds: elapsed,
            tokenCount: tokenCount
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
