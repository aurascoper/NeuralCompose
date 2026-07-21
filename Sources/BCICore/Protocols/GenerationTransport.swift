import Foundation

/// A `GenerationTransport` is the transport-level abstraction a
/// `GenerationRuntime` composes over. The transport is responsible
/// only for moving a `GenerationTransportRequest` to the provider
/// and returning a `GenerationTransportResponse`; it does NOT
/// rewrite prompts, alter temperatures, inject system instructions,
/// or interpret outputs. (ADR-009 invariant #2 — the runtime is
/// transport; the engine owns semantics.)
///
/// Concretely: a transport is one of these shapes:
///   - `ClaudeCLITransport` — `claude -p` subprocess (this branch).
///   - `OllamaHTTPTransport` — HTTP POST to `localhost:11434/api/generate`
///     (next iteration).
///   - `FakeTransport` (test-only) — returns canned responses for
///     unit tests.
///   - `RecordTransport` / `ReplayTransport` (future) — record
///     transport calls to disk and replay them for offline runs.
///
/// Adding a new model behind an existing transport is a
/// configuration change (set the `model` field on the request). Adding
/// a new transport shape is a new conformer to this protocol.
public protocol GenerationTransport: Sendable {
    /// The transport name (e.g. `claude-cli`, `ollama-http`). Identifies
    /// the shape, not the model.
    var transportName: String { get }

    /// The provider name (e.g. `anthropic`, `ollama`, `openai`). The
    /// `runtime / transport / provider` triple identifies the
    /// generator end-to-end; the model is configuration.
    var providerName: String { get }

    /// Send `request` to the provider and return the raw response.
    /// The transport MUST NOT modify the request's prompt text or
    /// system prompt; it MUST pass the request bytes verbatim.
    func send(_ request: GenerationTransportRequest) async throws -> GenerationTransportResponse
}

/// The request shape a transport consumes. Distinct from
/// `GenerationRequest` (the runtime's view) so the transport surface
/// is decoupled from the runtime surface: a future transport could
/// have a different request shape (streaming, batching, etc.) without
/// changing the `GenerationRuntime` protocol.
public struct GenerationTransportRequest: Sendable, Equatable {
    public let model: String
    public let prompt: String
    public let systemPrompt: String
    public let temperature: Double?
    public let maxTokens: Int?
    public let stopSequences: [String]

    public init(
        model: String,
        prompt: String,
        systemPrompt: String,
        temperature: Double? = nil,
        maxTokens: Int? = nil,
        stopSequences: [String] = []
    ) {
        self.model = model
        self.prompt = prompt
        self.systemPrompt = systemPrompt
        self.temperature = temperature
        self.maxTokens = maxTokens
        self.stopSequences = stopSequences
    }
}

/// The response shape a transport returns. The transport parses the
/// raw provider output into a text + metadata pair; the runtime
/// further shapes it into a `GenerationResult`.
public struct GenerationTransportResponse: Sendable, Equatable {
    public let text: String
    public let rawMetadata: [String: String]
    public let finishReason: GenerationResponse.FinishReason

    public init(
        text: String,
        rawMetadata: [String: String] = [:],
        finishReason: GenerationResponse.FinishReason = .endTurn
    ) {
        self.text = text
        self.rawMetadata = rawMetadata
        self.finishReason = finishReason
    }
}
