import XCTest
import BCICore
@testable import BCICloudBridge

final class LiveRuntimeFactoryTests: XCTestCase {

    func testExplicitOllamaSelectionProducesOllamaResolution() throws {
        let result = try LiveRuntimeFactory.make(
            runtimeName: "ollama",
            model: "qwen2.5:3b",
            systemPrompt: "test prompt"
        )

        XCTAssertEqual(result.resolved.name, "ollama")
        XCTAssertEqual(result.resolved.model, "qwen2.5:3b")
    }

    func testUnknownRuntimeFailsInsteadOfFallingBack() {
        XCTAssertThrowsError(
            try LiveRuntimeFactory.make(runtimeName: "not-a-runtime", model: nil)
        )
    }

    // MARK: - Claude path publishes metadata

    /// The app's Claude turns were logged with no `generatorFingerprint`
    /// because the factory returned a bare `ClaudeCLIGenerator`. The Claude
    /// path must publish metadata naming its runtime, model and profile.
    func testClaudePathPublishesMetadataNamingItsProfile() async throws {
        let stub = try ClaudeStub()
        defer { stub.remove() }

        let result = try LiveRuntimeFactory.make(
            runtimeName: "claude", model: "claude-sonnet-5",
            promptProfile: .wakingDialectical, claudeExecutablePath: stub.executable.path)
        var adapter = try XCTUnwrap(result.generator as? GenerationRuntimeTextGeneratingAdapter,
                                    "the Claude path must be metadata-publishing")
        let captured = MetadataCapture()
        adapter.onMetadata = { captured.set($0) }

        let reply = try await adapter.generate(
            prompt: "heard text", maxTokens: 10, temperature: 0.5, cancellationID: UUID())

        XCTAssertEqual(reply, "STUB REPLY")
        let metadata = try XCTUnwrap(captured.get(), "onMetadata must fire after a successful call")
        XCTAssertEqual(metadata.runtime, "claude-cli")
        XCTAssertEqual(metadata.model, "claude-sonnet-5")
        XCTAssertEqual(metadata.promptProfile, "wakingDialectical")
        XCTAssertEqual(metadata.promptHash, PromptProfile.sha256Hex(try PromptProfile.wakingDialectical.load()))
        XCTAssertEqual(result.resolved.systemPromptSource, "PromptProfile:wakingDialectical")
    }

    /// Moving onto the runtime must not change what leaves the device: the
    /// argv equals the legacy `ClaudeCLIGenerator`'s for the same prompt.
    func testClaudePathSendsTheSameArgvAsTheLegacyGenerator() async throws {
        let viaFactory = try ClaudeStub()
        let viaLegacy = try ClaudeStub()
        defer { viaFactory.remove(); viaLegacy.remove() }
        let promptText = try PromptProfile.witness.load()

        let factoryGen = try LiveRuntimeFactory.make(
            runtimeName: "claude", model: "claude-sonnet-5",
            promptProfile: .witness, claudeExecutablePath: viaFactory.executable.path).generator
        _ = try await factoryGen.generate(prompt: "heard text", maxTokens: 10, temperature: 1.0, cancellationID: UUID())
        let legacyGen = try ClaudeCLIGenerator(
            model: "claude-sonnet-5", systemPrompt: promptText, executablePath: viaLegacy.executable.path)
        _ = try await legacyGen.generate(prompt: "heard text", maxTokens: 10, temperature: 1.0, cancellationID: UUID())

        XCTAssertEqual(try viaFactory.capturedArgs(), try viaLegacy.capturedArgs())
    }

    /// Caller-owned prompt text is recorded as `custom`, hashed over the bytes
    /// actually sent, never attributed to a named profile.
    func testCallerSuppliedPromptIsRecordedAsCustom() async throws {
        let stub = try ClaudeStub()
        defer { stub.remove() }

        let result = try LiveRuntimeFactory.make(
            runtimeName: "claude", model: "claude-sonnet-5",
            systemPrompt: "CALLER PROMPT", claudeExecutablePath: stub.executable.path)
        var adapter = try XCTUnwrap(result.generator as? GenerationRuntimeTextGeneratingAdapter)
        let captured = MetadataCapture()
        adapter.onMetadata = { captured.set($0) }
        _ = try await adapter.generate(prompt: "x", maxTokens: 1, temperature: 0, cancellationID: UUID())

        let metadata = try XCTUnwrap(captured.get())
        XCTAssertEqual(metadata.promptProfile, "custom")
        XCTAssertEqual(metadata.promptHash, PromptProfile.sha256Hex("CALLER PROMPT"))
        XCTAssertEqual(result.resolved.systemPromptSource, "custom")
    }
}

/// A `claude` stand-in that records its argv (NUL-delimited, so a multi-line
/// system prompt stays one argument) and prints a valid JSON envelope.
private struct ClaudeStub {
    let executable: URL
    let argsFile: URL

    init() throws {
        let tmp = FileManager.default.temporaryDirectory
        executable = tmp.appendingPathComponent("claude-stub-\(UUID().uuidString).sh")
        argsFile = tmp.appendingPathComponent("claude-args-\(UUID().uuidString).txt")
        let script = """
        #!/bin/bash
        printf '%s\\0' "$@" > "\(argsFile.path)"
        printf '{"result":"STUB REPLY","is_error":false}'
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    }

    func capturedArgs() throws -> [String] {
        try String(contentsOf: argsFile, encoding: .utf8)
            .split(separator: "\u{0}", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    func remove() {
        try? FileManager.default.removeItem(at: executable)
        try? FileManager.default.removeItem(at: argsFile)
    }
}

private final class MetadataCapture: @unchecked Sendable {
    private let lock = NSLock()
    private var metadata: GenerationMetadata?
    func set(_ m: GenerationMetadata) { lock.lock(); metadata = m; lock.unlock() }
    func get() -> GenerationMetadata? { lock.lock(); defer { lock.unlock() }; return metadata }
}
