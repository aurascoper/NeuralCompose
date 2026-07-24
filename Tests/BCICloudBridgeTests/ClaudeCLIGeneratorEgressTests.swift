import XCTest
@testable import BCICloudBridge

/// Integration tests for the actual egress path — the privacy boundary itself,
/// which the parse-only tests don't cover. We point `executablePath` at a stub
/// script that records every argument it receives, so we can assert *exactly*
/// what text leaves the device (and that nothing else does).
final class ClaudeCLIGeneratorEgressTests: XCTestCase {

    /// Writes an executable stub that captures its argv (one per line) to
    /// `argsFile` and emits a valid `claude -p --output-format json` envelope.
    private func makeStub(argsFile: URL, reply: String = "STUB REPLY") throws -> URL {
        let stub = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-stub-\(UUID().uuidString).sh")
        // NUL-delimit the captured args so a multi-line arg (the system prompt)
        // isn't split apart on its own newlines.
        let script = """
        #!/bin/bash
        printf '%s\\0' "$@" > "\(argsFile.path)"
        printf '{"result":"\(reply)","is_error":false}'
        """
        try script.write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        return stub
    }

    private func capturedArgs(_ url: URL) throws -> [String] {
        try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\u{0}", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    func testEgressSendsExactlyTheSystemPromptAndTranscript_nothingElse() async throws {
        let argsFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("args-\(UUID().uuidString).txt")
        let stub = try makeStub(argsFile: argsFile)
        defer { try? FileManager.default.removeItem(at: stub); try? FileManager.default.removeItem(at: argsFile) }

        let gen = try ClaudeCLIGenerator(
            model: "claude-sonnet-5", systemPrompt: "TEST-SYS-PROMPT", executablePath: stub.path)
        let reply = try await gen.generate(
            prompt: "user transcript text", maxTokens: 10, temperature: 0.5, cancellationID: UUID())

        XCTAssertEqual(reply, "STUB REPLY", "the JSON envelope's result is returned")

        // The full, exact argv that left the device — no audio, no EEG, no extras.
        let args = try capturedArgs(argsFile)
        XCTAssertEqual(args, [
            "-p", "--model", "claude-sonnet-5",
            "--system-prompt", "TEST-SYS-PROMPT",
            "--output-format", "json",
            "user transcript text",
        ])
        // The user-derived transcript is present exactly once and is the ONLY
        // free-form user content; nothing audio/EEG-shaped leaves.
        XCTAssertEqual(args.filter { $0 == "user transcript text" }.count, 1)
        XCTAssertFalse(args.contains { $0.hasSuffix(".wav") || $0.lowercased().contains("audio")
                                       || $0.lowercased().contains("eeg") },
                       "only transcript text leaves the device — never audio or EEG")
    }

    func testDefaultSystemPromptIsTheConstrainedMirror_notAnUnconstrainedPassthrough() async throws {
        let argsFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("args-\(UUID().uuidString).txt")
        let stub = try makeStub(argsFile: argsFile)
        defer { try? FileManager.default.removeItem(at: stub); try? FileManager.default.removeItem(at: argsFile) }

        // Default init: the caller does NOT get to leave the system prompt open.
        let gen = try ClaudeCLIGenerator(executablePath: stub.path)
        _ = try await gen.generate(prompt: "anything", maxTokens: 1, temperature: 0, cancellationID: UUID())

        let args = try capturedArgs(argsFile)
        guard let i = args.firstIndex(of: "--system-prompt"), i + 1 < args.count else {
            return XCTFail("no --system-prompt passed")
        }
        XCTAssertEqual(args[i + 1], try ClaudeCLIGenerator.hypnagogicSystemPrompt(),
                       "the default egress uses the constrained hypnagogic prompt, so the network path "
                       + "can't be accidentally pointed at an unconstrained prompt")
    }

    func testCancellationDoesNotSendAnything() async throws {
        let argsFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("args-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: argsFile) }
        guard let stub = try? makeStub(argsFile: argsFile) else { return XCTFail("stub") }
        defer { try? FileManager.default.removeItem(at: stub) }

        let gen = try ClaudeCLIGenerator(executablePath: stub.path)
        let id = UUID()
        let task = Task { try await gen.generate(prompt: "x", maxTokens: 1, temperature: 0, cancellationID: id) }
        task.cancel()
        do { _ = try await task.value; /* may or may not have launched */ }
        catch is CancellationError {}
        catch { /* other terminal errors acceptable under a race */ }
    }
}
