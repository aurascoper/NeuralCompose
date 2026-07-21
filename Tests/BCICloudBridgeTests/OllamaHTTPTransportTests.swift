import XCTest
import Foundation
@testable import BCICloudBridge
@testable import BCICore

/// Tests for `OllamaHTTPTransport` (the local-HTTP transport for
/// Ollama-served models) and `OllamaGenerationRuntime` (the
/// `GenerationRuntime` conformer composed over it).
///
/// Level 1 (the keep-bar): the Ollama runtime must produce
/// byte-equivalent prompt text to the Claude runtime for the same
/// `PromptProfile` (the prompt-portability hypothesis). The
/// transport's `composePrompt(systemPrompt:userPrompt:)` is the
/// surface this test exercises: the bytes concatenated and sent
/// to Ollama are the Markdown-loaded system prompt + a documented
/// delimiter + the user's prompt text, in that order, with no
/// re-instruction.
///
/// Level 2: the transport shape has no Claude-specific
/// assumptions. `OllamaHTTPTransport` is a different
/// `GenerationTransport` than `ClaudeCLITransport`; both satisfy
/// the same protocol. A future `RecordTransport` /
/// `ReplayTransport` is a third conformer. The runtime composes
/// any of them via the same `generate(prompt:context:)` path.
final class OllamaHTTPTransportTests: XCTestCase {

    // MARK: - Encoding

    func testEncodeRequestIncludesModel() throws {
        let body = try OllamaHTTPTransport.encodeRequest(.init(
            model: "qwen2.5:0.5b", prompt: "hi", systemPrompt: "sys"
        ))
        let obj = try JSONSerialization.jsonObject(with: body) as! [String: Any]
        XCTAssertEqual(obj["model"] as? String, "qwen2.5:0.5b")
        XCTAssertEqual(obj["stream"] as? Bool, false)
    }

    func testEncodeRequestComposesPromptWithDelimiter() throws {
        let body = try OllamaHTTPTransport.encodeRequest(.init(
            model: "m", prompt: "user-text", systemPrompt: "system-text"
        ))
        let obj = try JSONSerialization.jsonObject(with: body) as! [String: Any]
        let composedPrompt = obj["prompt"] as! String
        XCTAssertTrue(composedPrompt.contains("system-text"))
        XCTAssertTrue(composedPrompt.contains("user-text"))
        XCTAssertTrue(composedPrompt.contains(OllamaHTTPTransport.systemPromptDelimiter))
    }

    func testEncodeRequestSystemPromptVerbatim() throws {
        // The system-prompt bytes are passed verbatim (ADR-009
        // invariant #2). The keep-bar is: the bytes the transport
        // sends are the bytes the Markdown file declares.
        let sys = "You are a voice in a live, waking dialectical exchange. 你好"
        let body = try OllamaHTTPTransport.encodeRequest(.init(
            model: "m", prompt: "p", systemPrompt: sys
        ))
        let obj = try JSONSerialization.jsonObject(with: body) as! [String: Any]
        let composedPrompt = obj["prompt"] as! String
        XCTAssertTrue(composedPrompt.contains(sys),
                      "system prompt bytes must round-trip verbatim")
    }

    func testEncodeRequestNoSystemPrompt() throws {
        // An empty system prompt must not produce a delimiter; the
        // runtime is a no-op in that case.
        let body = try OllamaHTTPTransport.encodeRequest(.init(
            model: "m", prompt: "user-text", systemPrompt: ""
        ))
        let obj = try JSONSerialization.jsonObject(with: body) as! [String: Any]
        let composedPrompt = obj["prompt"] as! String
        XCTAssertEqual(composedPrompt, "user-text")
    }

    func testEncodeRequestOptionalTemperature() throws {
        let body = try OllamaHTTPTransport.encodeRequest(.init(
            model: "m", prompt: "p", systemPrompt: "s",
            temperature: 0.4
        ))
        let obj = try JSONSerialization.jsonObject(with: body) as! [String: Any]
        let options = obj["options"] as! [String: Any]
        XCTAssertEqual(options["temperature"] as? Double, 0.4)
    }

    func testEncodeRequestOptionalMaxTokens() throws {
        let body = try OllamaHTTPTransport.encodeRequest(.init(
            model: "m", prompt: "p", systemPrompt: "s",
            maxTokens: 256
        ))
        let obj = try JSONSerialization.jsonObject(with: body) as! [String: Any]
        let options = obj["options"] as! [String: Any]
        XCTAssertEqual(options["num_predict"] as? Int, 256)
    }

    func testEncodeRequestOptionalStopSequences() throws {
        let body = try OllamaHTTPTransport.encodeRequest(.init(
            model: "m", prompt: "p", systemPrompt: "s",
            stopSequences: ["STOP", "END"]
        ))
        let obj = try JSONSerialization.jsonObject(with: body) as! [String: Any]
        let options = obj["options"] as! [String: Any]
        XCTAssertEqual(options["stop"] as? [String], ["STOP", "END"])
    }

    // MARK: - Decoding

    func testParseResponseValidJSON() throws {
        let data = #"{"model":"qwen2.5:0.5b","response":"pong","done":true,"done_reason":"stop","prompt_eval_count":36,"eval_count":3,"total_duration":1607727083}"#
            .data(using: .utf8)!
        let response = try OllamaHTTPTransport.parseResponse(data)
        XCTAssertEqual(response.text, "pong")
        XCTAssertEqual(response.rawMetadata["model"], "qwen2.5:0.5b")
        XCTAssertEqual(response.rawMetadata["eval_count"], "3")
        XCTAssertEqual(response.rawMetadata["prompt_eval_count"], "36")
        XCTAssertEqual(response.rawMetadata["latency_ms"], "1607")
        XCTAssertEqual(response.finishReason, .stopSequence)
    }

    func testParseResponseLengthFinishReason() throws {
        let data = #"{"response":"partial","done":true,"done_reason":"length"}"#.data(using: .utf8)!
        let response = try OllamaHTTPTransport.parseResponse(data)
        XCTAssertEqual(response.finishReason, .maxTokens)
    }

    func testParseResponseLoadFinishReason() throws {
        let data = #"{"response":"","done":true,"done_reason":"load"}"#.data(using: .utf8)!
        let response = try OllamaHTTPTransport.parseResponse(data)
        XCTAssertEqual(response.finishReason, .error)
    }

    func testParseResponseMissingField() {
        let data = #"{"done":true}"#.data(using: .utf8)!
        XCTAssertThrowsError(try OllamaHTTPTransport.parseResponse(data))
    }

    func testParseResponseNonJSON() {
        let data = "not json".data(using: .utf8)!
        XCTAssertThrowsError(try OllamaHTTPTransport.parseResponse(data))
    }

    // MARK: - Transport: shape

    func testTransportNames() {
        let t = OllamaHTTPTransport()
        XCTAssertEqual(t.transportName, "ollama-http")
        XCTAssertEqual(t.providerName, "ollama")
    }

    // MARK: - Runtime: composition

    func testRuntimeComposesTransport() {
        let r = OllamaGenerationRuntime(
            model: "qwen2.5:0.5b",
            promptProfile: .wakingDialectical,
            interactionStyle: "dialectical"
        )
        XCTAssertEqual(r.runtimeName, "ollama")
        XCTAssertEqual(r.modelIdentifier, "qwen2.5:0.5b (ollama)")
        XCTAssertTrue(r.isLive)
    }

    func testRuntimeAdvertisesTokenCounting() {
        // Ollama exposes eval_count; the runtime advertises
        // tokenCounting: true. The Claude runtime does not. This
        // is the capability-advertised keep-bar (ADR-009 #4) in
        // action.
        let ollama = OllamaGenerationRuntime(model: "m", systemPrompt: "s")
        XCTAssertTrue(ollama.capabilities.tokenCounting)
        XCTAssertFalse(ollama.capabilities.streaming)
        XCTAssertFalse(ollama.capabilities.logProbs)
    }

    func testRuntimeSystemPromptOverridePath() {
        let r = OllamaGenerationRuntime(
            model: "m",
            systemPrompt: "explicit"
        )
        XCTAssertEqual(r.modelIdentifier, "m (ollama)")
    }

    // MARK: - Live integration

    /// Live integration test against the local Ollama instance. The
    /// test is skipped if Ollama is not reachable or the
    /// `qwen2.5:0.5b` model is not pulled. The test exercises the
    /// full runtime: `OllamaHTTPTransport.send` → Ollama daemon →
    /// response parsing → `GenerationResult` with full metadata.
    ///
    /// This is the Level-1 keep-bar at the integration boundary:
    /// the runtime talks to a real provider and produces a real
    /// `GenerationResult`. The test asserts the metadata fields
    /// (transport, provider, model, promptHash, promptProfile,
    /// interactionStyle, tokenCount) are populated correctly when
    /// the runtime is composed over the real transport.
    func testLiveRuntimeHitsOllama() async throws {
        guard await isOllamaReachable() else {
            throw XCTSkip("Ollama not reachable on http://localhost:11434")
        }
        guard await isModelPulled("qwen2.5:0.5b") else {
            throw XCTSkip("qwen2.5:0.5b not pulled on this Ollama instance")
        }
        let r = OllamaGenerationRuntime(
            model: "qwen2.5:0.5b",
            systemPrompt: "Reply with the single word: pong"
        )
        let result = try await r.generate(
            prompt: "ping",
            context: GenerationContext(generationParameters: .init(temperature: 0.0))
        )
        XCTAssertFalse(result.text.isEmpty)
        XCTAssertEqual(result.metadata.runtime, "ollama")
        XCTAssertEqual(result.metadata.transport, "ollama-http")
        XCTAssertEqual(result.metadata.provider, "ollama")
        XCTAssertEqual(result.metadata.model, "qwen2.5:0.5b")
        XCTAssertFalse(result.metadata.promptHash.isEmpty)
        XCTAssertEqual(result.metadata.promptProfile, "wakingDialectical")
        XCTAssertEqual(result.metadata.interactionStyle, "dialectical")
        // Token counting is advertised; the live response populates it.
        XCTAssertNotNil(result.metadata.tokenCount)
    }

    private func isOllamaReachable() async -> Bool {
        guard let url = URL(string: "http://localhost:11434/api/tags") else { return false }
        do {
            let (_, response) = try await URLSession.shared.data(from: url)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    private func isModelPulled(_ model: String) async -> Bool {
        guard let url = URL(string: "http://localhost:11434/api/tags") else { return false }
        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let models = obj["models"] as? [[String: Any]] else { return false }
            return models.contains { ($0["name"] as? String) == model }
        } catch {
            return false
        }
    }
}
