import BCICore
import Foundation

/// `OllamaHTTPTransport` is a `GenerationTransport` that drives an
/// Ollama-hosted model through Ollama's local HTTP API
/// (`POST /api/generate`). Ollama is the user-installed daemon
/// (`ollama serve`, default `http://localhost:11434`); this transport
/// speaks the `/api/generate` endpoint with `stream: false`.
///
/// ADR-009 invariant #3: a new model behind an existing transport is
/// a configuration change, not a Swift type. The model name is
/// supplied via `GenerationTransportRequest.model`; this transport
/// passes it through verbatim to Ollama. The same transport can
/// drive `deepseek-v4-flash:cloud`, `qwen2.5:3b`, `qwen2.5:1.5b`,
/// `qwen2.5:0.5b`, `deepseek-r1:1.5b`, or any other model the
/// user's Ollama instance has pulled.
///
/// ADR-009 invariant #2: the transport MUST NOT modify semantic
/// intent. The prompt text and system prompt bytes are passed
/// verbatim; the temperature / max-tokens parameters are forwarded
/// when present and ignored when absent (Ollama's API uses its
/// own defaults). The transport does not rewrite, summarize, or
/// re-instruct.
///
/// Network-egress surface: the user's Ollama instance. For
/// `deepseek-v4-flash:cloud` (a `:cloud`-suffixed model) the
/// user's Ollama account routes the call to the cloud; for
/// un-suffixed models the call is local. Each non-local model is
/// its own opt-in surface; the privacy banner discloses the
/// active model and the call count.
///
/// Why the runtime doesn't directly compose a transport is the
/// point of this layer: the dialectical engine depends on
/// `GenerationRuntime`; `GenerationRuntime` composes a
/// `GenerationTransport`; `GenerationTransport` is whatever
/// transport is appropriate. A future `OllamaChatTransport`
/// (using `/api/chat` with a messages array) or a
/// `RecordTransport` (writing to disk) is a new conformer to
/// `GenerationTransport` — not a new conformer to `GenerationRuntime`.
public struct OllamaHTTPTransport: GenerationTransport {
    public let transportName = "ollama-http"
    public let providerName = "ollama"

    /// The base URL of the Ollama HTTP API. Default
    /// `http://localhost:11434`. Override for a non-default port
    /// or a remote Ollama instance.
    public let baseURL: URL

    /// The session used to make HTTP requests. Configurable for
    /// testing (a `URLSession` with a mock `URLProtocol`).
    public let session: URLSession

    public init(
        baseURL: URL = URL(string: "http://localhost:11434")!,
        session: URLSession? = nil
    ) {
        self.baseURL = baseURL
        // Each OllamaHTTPTransport gets its OWN URLSession — using
        // `URLSession.shared` is a known concurrency hazard for
        // serial calls under load (calls serialize on a shared
        // completion queue, and with cloud-routed models the
        // HTTP-keep-alive behavior can cause spurious 60s+ hangs
        // on the second-and-onward call in a rapid sequence).
        // Use `.ephemeral` to disable keep-alive: every request
        // opens a fresh TCP connection. This is a 1-2ms cost
        // per call and eliminates the bug class entirely.
        // Configured session also has a 30s request timeout.
        if let session { self.session = session }
        else {
            let cfg = URLSessionConfiguration.ephemeral
            cfg.timeoutIntervalForRequest = 30
            cfg.timeoutIntervalForResource = 120
            self.session = URLSession(configuration: cfg)
        }
    }

    public func send(_ request: GenerationTransportRequest) async throws -> GenerationTransportResponse {
        let url = baseURL.appendingPathComponent("api/generate")
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try Self.encodeRequest(request)
        urlRequest.timeoutInterval = 30

        let (data, response) = try await session.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse else {
            throw BCIError.predictorInferenceFailed(reason: "Ollama returned a non-HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "<no body>"
            throw BCIError.predictorInferenceFailed(
                reason: "Ollama HTTP \(http.statusCode): \(body)"
            )
        }
        return try Self.parseResponse(data)
    }

    // MARK: - Encoding (static + pure, unit-testable)

    /// Encode a `GenerationTransportRequest` into the JSON body
    /// Ollama's `/api/generate` endpoint expects.
    ///
    /// The system prompt is concatenated onto the user prompt with
    /// a delimiter because Ollama's `/api/generate` does not
    /// natively accept a system role; this concatenation preserves
    /// the system-prompt bytes for the model without
    /// re-instructing (ADR-009 invariant #2). The exact delimiter
    /// is documented in `Self.systemPromptDelimiter`.
    public static func encodeRequest(_ request: GenerationTransportRequest) throws -> Data {
        var body: [String: Any] = [
            "model": request.model,
            "prompt": composePrompt(systemPrompt: request.systemPrompt, userPrompt: request.prompt),
            "stream": false,
        ]
        if let t = request.temperature {
            body["options"] = (body["options"] as? [String: Any] ?? [:])
                .merging(["temperature": t], uniquingKeysWith: { _, new in new })
        }
        if let m = request.maxTokens {
            body["options"] = (body["options"] as? [String: Any] ?? [:])
                .merging(["num_predict": m], uniquingKeysWith: { _, new in new })
        }
        if !request.stopSequences.isEmpty {
            body["options"] = (body["options"] as? [String: Any] ?? [:])
                .merging(["stop": request.stopSequences], uniquingKeysWith: { _, new in new })
        }
        return try JSONSerialization.data(withJSONObject: body)
    }

    /// The delimiter used to concatenate the system prompt and
    /// user prompt before sending to Ollama. Two newlines + a
    /// directive marker so the model clearly distinguishes the
    /// system-role content from the user-role content even though
    /// Ollama's `/api/generate` does not have a `system` field.
    public static let systemPromptDelimiter = "\n\n# System\n\n"

    /// Compose the system prompt + user prompt for Ollama's
    /// `/api/generate` endpoint. The system prompt bytes are
    /// preserved verbatim (ADR-009 invariant #2).
    public static func composePrompt(systemPrompt: String, userPrompt: String) -> String {
        if systemPrompt.isEmpty {
            return userPrompt
        }
        return systemPrompt + systemPromptDelimiter + userPrompt
    }

    // MARK: - Decoding (static + pure, unit-testable)

    /// Parse Ollama's `/api/generate` response envelope.
    /// The response JSON is:
    /// ```
    /// {
    ///   "model": "...",
    ///   "response": "<generated text>",
    ///   "done": true,
    ///   "done_reason": "stop",
    ///   "context": [...],
    ///   "total_duration": <ns>,
    ///   "load_duration": <ns>,
    ///   "prompt_eval_count": <int>,
    ///   "eval_count": <int>,
    ///   ...
    /// }
    /// ```
    public static func parseResponse(_ data: Data) throws -> GenerationTransportResponse {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw BCIError.predictorInferenceFailed(reason: "Ollama returned non-JSON output")
        }
        guard let response = obj["response"] as? String else {
            throw BCIError.predictorInferenceFailed(reason: "Ollama JSON missing 'response' field")
        }
        var rawMetadata: [String: String] = [:]
        if let model = obj["model"] as? String { rawMetadata["model"] = model }
        if let totalDuration = obj["total_duration"] as? Double {
            // Ollama durations are nanoseconds; expose milliseconds.
            rawMetadata["latency_ms"] = String(Int(totalDuration / 1_000_000))
        }
        if let promptEval = obj["prompt_eval_count"] as? Int {
            rawMetadata["prompt_eval_count"] = String(promptEval)
        }
        if let evalCount = obj["eval_count"] as? Int {
            rawMetadata["eval_count"] = String(evalCount)
        }
        let finishReason: GenerationResponse.FinishReason = {
            switch (obj["done_reason"] as? String)?.lowercased() {
            case "stop": return .stopSequence
            case "length": return .maxTokens
            case "load": return .error
            default: return .endTurn
            }
        }()
        return GenerationTransportResponse(
            text: response,
            rawMetadata: rawMetadata,
            finishReason: finishReason
        )
    }
}
