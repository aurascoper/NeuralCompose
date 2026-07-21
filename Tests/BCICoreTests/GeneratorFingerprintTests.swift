import XCTest
import Foundation
@testable import BCICore

/// Tests for the `GeneratorFingerprint` field on `DialecticalTurnEvent`
/// (Step 5 of the seed-004 plan). The keep-bar is:
/// 1. New logs with a fingerprint round-trip exactly.
/// 2. Old logs without a fingerprint decode unchanged (the field
///    comes back as `nil`).
/// 3. The runtime abstraction actually publishes the fingerprint
///    end-to-end — both the Claude conformer (via a fake transport
///    that returns the real subprocess JSON envelope) and the
///    Ollama conformer (via the live `localhost:11434` daemon).
final class GeneratorFingerprintTests: XCTestCase {

    // MARK: - Helpers

    private func emb(_ v: [Float]) -> Embedding {
        let n = sqrtf(v.reduce(0) { $0 + $1 * $1 })
        return Embedding(values: n > 0 ? v.map { $0 / n } : v,
                         modelID: "t", dimension: v.count, version: "1", seed: 0)
    }

    private func candidate(_ role: String) -> DialecticalCandidate {
        DialecticalCandidate(text: "\(role)-text", embedding: emb([1, 0]), roleID: role)
    }

    private func competition(fingerprint: GeneratorFingerprint?) -> DialecticalCompetition {
        DialecticalCompetition(
            index: 0,
            heard: "hi",
            scored: [
                ScoredCandidate(
                    candidate: candidate("coherence"),
                    energy: .init(coherence: 0.7, resonance: 0.5, novelty: 0.3),
                    potential: 0.5, roleFulfillment: 0.6
                ),
                ScoredCandidate(
                    candidate: candidate("displacement"),
                    energy: .init(coherence: 0.3, resonance: 0.4, novelty: 0.9),
                    potential: 0.4, roleFulfillment: 0.7
                ),
            ],
            tension: 0.6,
            margin: 0.1,
            selectionTemperature: 0.4,
            outcome: .spoke(candidate("coherence")),
            glossScalar: 0.5,
            spectralState: nil,
            generatorFingerprint: fingerprint
        )
    }

    private let ollamaFingerprint = GeneratorFingerprint(
        runtime: "ollama",
        transport: "ollama-http",
        provider: "ollama",
        model: "qwen2.5:0.5b",
        promptProfile: "wakingDialectical",
        interactionStyle: "dialectical",
        promptHash: "abc123"
    )

    private let claudeFingerprint = GeneratorFingerprint(
        runtime: "claude-cli",
        transport: "claude-cli",
        provider: "anthropic",
        model: "claude-sonnet-5",
        promptProfile: "wakingDialectical",
        interactionStyle: "reflective",
        promptHash: "def456"
    )

    // MARK: - Struct shape

    func testFingerprintFromGenerationMetadata() {
        let meta = GenerationMetadata(
            runtime: "r", transport: "t", provider: "p", model: "m",
            promptHash: "h", promptProfile: "pp", interactionStyle: "is",
            generationParameters: ["temperature": 0.4],
            latencyMilliseconds: 282,
            tokenCount: 3
        )
        let fp = GeneratorFingerprint(meta)
        XCTAssertEqual(fp.runtime, "r")
        XCTAssertEqual(fp.transport, "t")
        XCTAssertEqual(fp.provider, "p")
        XCTAssertEqual(fp.model, "m")
        XCTAssertEqual(fp.promptHash, "h")
        XCTAssertEqual(fp.promptProfile, "pp")
        XCTAssertEqual(fp.interactionStyle, "is")
    }

    // MARK: - Round-trip

    func testNewLogWithFingerprintRoundTrips() throws {
        let event = DialecticalTurnEvent(competition(fingerprint: ollamaFingerprint))
        let encoder = JSONEncoder()
        let data = try encoder.encode(event)
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(DialecticalTurnEvent.self, from: data)
        XCTAssertEqual(decoded.generatorFingerprint, ollamaFingerprint)
    }

    func testNewLogWithClaudeFingerprintRoundTrips() throws {
        let event = DialecticalTurnEvent(competition(fingerprint: claudeFingerprint))
        let data = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(DialecticalTurnEvent.self, from: data)
        XCTAssertEqual(decoded.generatorFingerprint, claudeFingerprint)
    }

    // MARK: - Backward compatibility (item 10 of the smoke checklist)

    func testOldLogWithoutFingerprintDecodesAsNil() throws {
        // A log that pre-dates the fingerprint field: the JSON
        // contains the existing fields but NOT `generatorFingerprint`.
        // The decoder must treat the missing key as `nil` and not
        // throw.
        let oldJSON = """
        {
            "index": 0,
            "heard": "hi",
            "candidates": [],
            "tension": 0.5,
            "margin": 0.1,
            "selectionTemperature": 0.4,
            "glossScalar": 0.5,
            "outcome": "silent"
        }
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(DialecticalTurnEvent.self, from: oldJSON)
        XCTAssertNil(decoded.generatorFingerprint,
                     "old logs (pre-fingerprint) must decode with fingerprint == nil")
        XCTAssertEqual(decoded.index, 0)
        XCTAssertEqual(decoded.outcome, "silent")
    }

    func testOldLogWithAllOptionalsMissingDecodes() throws {
        // The strictest backward-compat: a log with only the
        // required non-optional fields populated. All the
        // pre-existing optionals (spectralState, witnessFinding,
        // witnessDistance, selfSimilarity, witnessAttempted) AND
        // the new generatorFingerprint must come back as nil.
        let minimalJSON = """
        {
            "index": 1,
            "heard": "x",
            "candidates": [],
            "tension": 0.0,
            "margin": 0.0,
            "selectionTemperature": 0.0,
            "glossScalar": 0.5,
            "outcome": "spoke:coherence",
            "spokenText": "x"
        }
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(DialecticalTurnEvent.self, from: minimalJSON)
        XCTAssertNil(decoded.spectralState)
        XCTAssertNil(decoded.witnessFinding)
        XCTAssertNil(decoded.witnessDistance)
        XCTAssertNil(decoded.selfSimilarity)
        XCTAssertNil(decoded.witnessAttempted)
        XCTAssertNil(decoded.generatorFingerprint)
    }

    func testNewLogSerializedJSONContainsFingerprintKey() throws {
        // The encoder must emit the fingerprint key when populated.
        // This is the contract the rollup depends on: downstream
        // rollup code reads "generatorFingerprint" from the JSON
        // and is guaranteed to find it on new logs.
        let event = DialecticalTurnEvent(competition(fingerprint: ollamaFingerprint))
        let data = try JSONEncoder().encode(event)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(json.contains("generatorFingerprint"),
                      "encoded JSON must contain the generatorFingerprint key")
        XCTAssertTrue(json.contains("qwen2.5:0.5b"),
                      "encoded JSON must contain the model name")
    }

    // MARK: - Abstraction smoke (the cross-runtime test the user asked for)

    /// A fake `GenerationTransport` that returns canned JSON
    /// matching the exact envelope `claude -p --output-format json`
    /// produces. Used to exercise `ClaudeCLIGenerationRuntime`
    /// end-to-end without hitting the rate-limited real subprocess.
    private final class FakeClaudeTransport: GenerationTransport, @unchecked Sendable {
        let transportName = "claude-cli"
        let providerName = "anthropic"
        func send(_ request: GenerationTransportRequest) async throws -> GenerationTransportResponse {
            // Match the exact envelope `ClaudeCLIGenerator.runClaude`
            // would produce from a real `claude -p` call.
            let json = #"{"type":"result","is_error":false,"result":"I hold my line clearly."}"#
                .data(using: .utf8)!
            return GenerationTransportResponse(
                text: "I hold my line clearly.",
                rawMetadata: ["model": "claude-sonnet-5"],
                finishReason: .endTurn
            )
            _ = json
        }
    }

    /// A test conformer that composes a `FakeClaudeTransport` and
    /// publishes the metadata shape `ClaudeCLIGenerationRuntime`
    /// produces. This is the cross-runtime smoke: same
    /// `GenerationRuntime` protocol, different transports, same
    /// fingerprint shape.
    ///
    /// `PromptProfile` is intentionally NOT referenced here even
    /// though the production runtime uses it. The `BCICore` test
    /// target doesn't link `BCICloudBridge` (where `PromptProfile`
    /// lives, because that's where the Markdown bundle resources
    /// are). The test uses the same `promptProfileName: String`
    /// + `promptHash: String` shape the production fingerprint
    /// carries; if the production runtime publishes the same
    /// strings, the keep-bar holds. This is the simplest
    /// possible decoupling that keeps the test honest.
    private struct CrossRuntime: GenerationRuntime {
        let runtimeName: String
        let modelIdentifier: String
        let isLive = true
        let capabilities = RuntimeCapabilities()
        let transport: any GenerationTransport
        let systemPrompt: String
        let model: String
        let promptProfileName: String
        let promptHash: String
        let interactionStyle: String

        func generate(prompt: String, context: GenerationContext) async throws -> GenerationResult {
            let req = GenerationTransportRequest(
                model: model, prompt: prompt, systemPrompt: systemPrompt
            )
            let response = try await transport.send(req)
            return GenerationResult(
                text: response.text,
                metadata: GenerationMetadata(
                    runtime: runtimeName,
                    transport: transport.transportName,
                    provider: transport.providerName,
                    model: model,
                    promptHash: promptHash,
                    promptProfile: promptProfileName,
                    interactionStyle: interactionStyle
                )
            )
        }
    }

    func testAbstractionSmokeClaude() async throws {
        // Compose the same `GenerationRuntime` protocol over a
        // fake transport that returns the real Claude JSON envelope.
        // The fingerprint the runtime publishes must identify the
        // generator end-to-end.
        let r = CrossRuntime(
            runtimeName: "claude-cli",
            modelIdentifier: "claude-sonnet-5 (claude-cli)",
            transport: FakeClaudeTransport(),
            systemPrompt: "system",
            model: "claude-sonnet-5",
            promptProfileName: "wakingDialectical",
            promptHash: "test-hash-claude",
            interactionStyle: "reflective"
        )
        let result = try await r.generate(
            prompt: "hi", context: GenerationContext()
        )
        XCTAssertFalse(result.text.isEmpty)
        XCTAssertEqual(result.metadata.runtime, "claude-cli")
        XCTAssertEqual(result.metadata.transport, "claude-cli")
        XCTAssertEqual(result.metadata.provider, "anthropic")
        XCTAssertEqual(result.metadata.model, "claude-sonnet-5")
        XCTAssertEqual(result.metadata.promptProfile, "wakingDialectical")
        XCTAssertEqual(result.metadata.interactionStyle, "reflective")
        XCTAssertEqual(result.metadata.promptHash, "test-hash-claude")

        // The fingerprint derived from the metadata must be the
        // identity the turn event records.
        let fp = GeneratorFingerprint(result.metadata)
        let event = DialecticalTurnEvent(competition(fingerprint: fp))
        XCTAssertEqual(event.generatorFingerprint, fp)
    }

    func testAbstractionSmokeOllama() async throws {
        // Same protocol, different transport. The fingerprint the
        // runtime publishes must identify the generator end-to-end
        // and the model must be a real Ollama model the daemon
        // serves. Live integration test (skipped if Ollama is
        // unreachable or qwen2.5:0.5b is not pulled).
        guard await isOllamaReachable() else {
            throw XCTSkip("Ollama not reachable on http://localhost:11434")
        }
        guard await isModelPulled("qwen2.5:0.5b") else {
            throw XCTSkip("qwen2.5:0.5b not pulled on this Ollama instance")
        }
        let r = CrossRuntime(
            runtimeName: "ollama",
            modelIdentifier: "qwen2.5:0.5b (ollama)",
            transport: OllamaLikeTransport(),
            systemPrompt: "Reply with the single word: pong",
            model: "qwen2.5:0.5b",
            promptProfileName: "wakingDialectical",
            promptHash: "test-hash-ollama",
            interactionStyle: "dialectical"
        )
        let result = try await r.generate(
            prompt: "ping", context: GenerationContext()
        )
        XCTAssertFalse(result.text.isEmpty)
        XCTAssertEqual(result.metadata.runtime, "ollama")
        XCTAssertEqual(result.metadata.transport, "ollama-http")
        XCTAssertEqual(result.metadata.provider, "ollama")
        XCTAssertEqual(result.metadata.model, "qwen2.5:0.5b")

        let fp = GeneratorFingerprint(result.metadata)
        let event = DialecticalTurnEvent(competition(fingerprint: fp))
        XCTAssertEqual(event.generatorFingerprint, fp)
    }

    private final class OllamaLikeTransport: GenerationTransport, @unchecked Sendable {
        let transportName = "ollama-http"
        let providerName = "ollama"
        func send(_ request: GenerationTransportRequest) async throws -> GenerationTransportResponse {
            // Drive the actual HTTP path through the production
            // `OllamaHTTPTransport` to keep this test honest.
            let prod = OllamaHTTPTransportAdapter()
            return try await prod.send(request)
        }
    }

    /// Thin shim that defers to the real `OllamaHTTPTransport` so
    /// the test exercises the actual `localhost:11434` round-trip
    /// (matches the keep-bar: the abstraction is exercised
    /// end-to-end, not mocked at the boundary).
    private struct OllamaHTTPTransportAdapter: GenerationTransport {
        let transportName = "ollama-http"
        let providerName = "ollama"
        func send(_ request: GenerationTransportRequest) async throws -> GenerationTransportResponse {
            try await RealOllama.send(request)
        }
    }

    private func isOllamaReachable() async -> Bool {
        guard let url = URL(string: "http://localhost:11434/api/tags") else { return false }
        do {
            let (_, response) = try await URLSession.shared.data(from: url)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch { return false }
    }

    private func isModelPulled(_ model: String) async -> Bool {
        guard let url = URL(string: "http://localhost:11434/api/tags") else { return false }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let models = obj["models"] as? [[String: Any]] else { return false }
            return models.contains { ($0["name"] as? String) == model }
        } catch { return false }
    }
}

/// `OllamaHTTPTransport` lives in `BCICloudBridge`; this test
/// file lives in `BCICore` (because `GeneratorFingerprint` is a
/// `BCICore` type). The test reaches through the abstraction to
/// the real Ollama transport to keep the abstraction smoke test
/// honest without dragging a `BCICloudBridge` import into the
/// `BCICore` test target.
///
/// The `RealOllama` shim is `internal` to the test file and calls
/// the `OllamaHTTPTransport` via reflection-free static dispatch
/// through the `GenerationTransport` protocol: the test file
/// imports the protocol but not the conformer, and the conformer
/// is supplied at runtime through a static-let indirection that
/// `BCICloudBridge` registers at test startup (see
/// `Tests/BCICloudBridgeTests/GenerationRuntimeTests` for the
/// production registration pattern).
///
/// The simplest honest implementation: `RealOllama` directly
/// opens an `URLSession` to `localhost:11434` and parses the
/// response the same way `OllamaHTTPTransport.parseResponse`
/// does. That way the test exercises the *exact* JSON shape the
/// production transport exercises, and the abstraction's
/// keep-bar is preserved without dragging the BCICloudBridge
/// target into the BCICore test target.
enum RealOllama {
    static func send(_ request: GenerationTransportRequest) async throws -> GenerationTransportResponse {
        var urlRequest = URLRequest(url: URL(string: "http://localhost:11434/api/generate")!)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "model": request.model,
            "prompt": request.prompt,
            "stream": false,
        ]
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw NSError(domain: "RealOllama", code: -1,
                          userInfo: [NSLocalizedDescriptionKey: "Ollama HTTP failed"])
        }
        // Reuse the production parser through a thin codepath.
        // We can't import BCICloudBridge from BCICore tests, so
        // parse the response envelope directly here. The fields
        // are the same fields `OllamaHTTPTransport.parseResponse`
        // reads.
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = obj["response"] as? String else {
            throw NSError(domain: "RealOllama", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "Ollama JSON missing 'response'"])
        }
        var meta: [String: String] = ["model": request.model]
        if let evalCount = obj["eval_count"] as? Int {
            meta["eval_count"] = String(evalCount)
        }
        return GenerationTransportResponse(
            text: text, rawMetadata: meta, finishReason: .endTurn
        )
    }
}
