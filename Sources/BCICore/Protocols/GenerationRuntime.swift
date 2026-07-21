import Foundation

/// A `GenerationContext` carries the optional contextual information a
/// `GenerationRuntime` may use when responding to a prompt. The runtime
/// SHALL NOT modify semantic intent (ADR-009 invariant #2): the
/// context is opaque metadata the runtime may surface to its
/// transport; it is NOT a license to rewrite, summarize, or
/// re-instruct. Concrete conformers may ignore fields they do not
/// need.
///
/// For now the context carries:
///   - prior turns (for multi-turn generation; ignored by
///     single-turn transports),
///   - model hints (free-form transport-specific strings),
///   - generation parameters (temperature, max tokens).
///
/// A minimal `TextGenerating`-equivalent call uses
/// `GenerationContext.empty` and the runtime behavior is byte-equivalent
/// to the legacy `TextGenerating.generate(...)` path. The default
/// implementation on `ClaudeCLIGenerationRuntime` does exactly that:
/// it composes a `GenerationTransportRequest` and discards prior-turns
/// / model-hints, because the underlying `claude -p` transport does
/// not consume them.
public struct GenerationContext: Sendable, Equatable {
    public struct Turn: Sendable, Equatable {
        public let role: Role
        public let text: String

        public enum Role: String, Sendable, Equatable {
            case user
            case assistant
            case system
        }

        public init(role: Role, text: String) {
            self.role = role
            self.text = text
        }
    }

    public struct GenerationParameters: Sendable, Equatable {
        public let temperature: Double?
        public let maxTokens: Int?

        public init(temperature: Double? = nil, maxTokens: Int? = nil) {
            self.temperature = temperature
            self.maxTokens = maxTokens
        }
    }

    public let priorTurns: [Turn]
    public let modelHints: [String: String]
    public let generationParameters: GenerationParameters

    public init(
        priorTurns: [Turn] = [],
        modelHints: [String: String] = [:],
        generationParameters: GenerationParameters = .init()
    ) {
        self.priorTurns = priorTurns
        self.modelHints = modelHints
        self.generationParameters = generationParameters
    }

    public static let empty = GenerationContext()
}

/// A `GenerationRequest` is the unit of work a `GenerationRuntime`
/// hands to its `GenerationTransport`. The transport is responsible
/// only for transporting the request and returning the response; it
/// does NOT modify the prompt text, the model name, or the
/// parameters. (ADR-009 invariant #2.)
public struct GenerationRequest: Sendable, Equatable {
    public let model: String
    public let prompt: String
    public let systemPrompt: String
    public let generationParameters: GenerationContext.GenerationParameters

    public init(
        model: String,
        prompt: String,
        systemPrompt: String,
        generationParameters: GenerationContext.GenerationParameters = .init()
    ) {
        self.model = model
        self.prompt = prompt
        self.systemPrompt = systemPrompt
        self.generationParameters = generationParameters
    }
}

/// A `GenerationResponse` is the raw transport-level response. The
/// runtime parses it into a `GenerationResult`. The raw response
/// preserves the provider's metadata so the runtime can publish it
/// in `GenerationMetadata`.
public struct GenerationResponse: Sendable, Equatable {
    public let text: String
    public let rawMetadata: [String: String]
    public let finishReason: FinishReason

    public enum FinishReason: String, Sendable, Equatable {
        /// The transport reported a clean completion.
        case endTurn = "end_turn"
        /// The transport reported a token-cap or length-cap stop.
        case maxTokens = "max_tokens"
        /// The transport reported a stop-sequence match.
        case stopSequence = "stop_sequence"
        /// The transport reported an error; the runtime converts this
        /// to a thrown `BCIError` before it ever reaches a `GenerationResult`.
        case error
        /// The transport did not report a finish reason. The runtime
        /// records `unknown` rather than guessing.
        case unknown
    }

    public init(
        text: String,
        rawMetadata: [String: String] = [:],
        finishReason: FinishReason = .endTurn
    ) {
        self.text = text
        self.rawMetadata = rawMetadata
        self.finishReason = finishReason
    }
}

/// A `GenerationResult` is what the `GenerationRuntime` returns to
/// the dialectical engine. The `text` is the model output; the
/// `metadata` is the runtime-published facts about the run.
public struct GenerationResult: Sendable, Equatable {
    public let text: String
    public let metadata: GenerationMetadata

    public init(text: String, metadata: GenerationMetadata) {
        self.text = text
        self.metadata = metadata
    }
}

/// `GenerationMetadata` is the runtime-published facts about a
/// generation. It is the dialectical engine's view of "what
/// provider / model / prompt produced this output." The
/// `GeneratorFingerprint` (the seed-004 telemetry struct) is
/// derived from this — same fields, same names.
public struct GenerationMetadata: Sendable, Equatable {
    public let runtime: String
    public let transport: String
    public let provider: String
    public let model: String
    public let promptHash: String
    public let promptProfile: String
    public let interactionStyle: String
    public let generationParameters: [String: Double]
    public let latencyMilliseconds: Int?
    public let tokenCount: Int?

    public init(
        runtime: String,
        transport: String,
        provider: String,
        model: String,
        promptHash: String,
        promptProfile: String,
        interactionStyle: String,
        generationParameters: [String: Double] = [:],
        latencyMilliseconds: Int? = nil,
        tokenCount: Int? = nil
    ) {
        self.runtime = runtime
        self.transport = transport
        self.provider = provider
        self.model = model
        self.promptHash = promptHash
        self.promptProfile = promptProfile
        self.interactionStyle = interactionStyle
        self.generationParameters = generationParameters
        self.latencyMilliseconds = latencyMilliseconds
        self.tokenCount = tokenCount
    }
}

/// `RuntimeCapabilities` advertises which optional methods of a
/// `GenerationRuntime` are functional. The runtime is
/// capability-advertised, not method-mandatory (ADR-009 invariant #4).
/// Conformers that do not implement a capability return `false` and
/// the runtime methods that depend on it return `nil` / a
/// best-effort value.
public struct RuntimeCapabilities: Sendable, Equatable {
    public let tokenCounting: Bool
    public let streaming: Bool
    public let logProbs: Bool

    public init(
        tokenCounting: Bool = false,
        streaming: Bool = false,
        logProbs: Bool = false
    ) {
        self.tokenCounting = tokenCounting
        self.streaming = streaming
        self.logProbs = logProbs
    }

    /// The default capabilities for a transport that does not advertise
    /// any of the optional behaviors.
    public static let none = RuntimeCapabilities()
}

/// A `GenerationRuntime` is the provider-neutral runtime surface the
/// dialectical engine depends on. It is composed over a
/// `GenerationTransport`; a new model behind an existing transport is
/// a configuration change, not a Swift type (ADR-009 invariant #3).
///
/// The runtime SHALL NOT modify semantic intent (invariant #2): it
/// passes the prompt and the system prompt bytes verbatim to the
/// transport, and it does not interpret, rewrite, or re-instruct the
/// response. The runtime owns transport; the dialectical engine owns
/// semantics.
///
/// The `TextGenerating` protocol is the legacy compatibility shim.
/// Conformers that need to bridge to legacy call sites can conform
/// to *both* `TextGenerating` and `GenerationRuntime`; the legacy
/// `generate(prompt:maxTokens:temperature:cancellationID:)` is
/// implemented as a thin wrapper around `generate(prompt:context:)`
/// with a `GenerationContext` carrying the legacy parameters.
public protocol GenerationRuntime: Sendable {
    /// The runtime name (e.g. `claude-cli`, `ollama`). Identifies the
    /// transport, not the model.
    var runtimeName: String { get }

    /// The model name (e.g. `claude-sonnet-5`, `deepseek-v4-flash:cloud`).
    /// Model is configuration; the transport is the type.
    var modelIdentifier: String { get }

    /// True if this runtime makes a real network call. False for stub
    /// conformers and for the on-device MLX path.
    var isLive: Bool { get }

    /// The capabilities this runtime advertises. Conformers that do
    /// not implement an optional capability return `false` and the
    /// corresponding runtime method returns `nil`.
    var capabilities: RuntimeCapabilities { get }

    /// Generate a response for `prompt` with `context`. The runtime
    /// passes the prompt + systemPrompt bytes to the transport
    /// verbatim and returns the response. The runtime does NOT
    /// modify semantic intent.
    func generate(
        prompt: String,
        context: GenerationContext
    ) async throws -> GenerationResult
}
