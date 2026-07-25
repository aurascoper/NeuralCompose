import BCICore
import XCTest
@testable import BCICloudBridge

/// The override branch of `ClaudeCLITransport.runClaude` passes `args`
/// unmodified. That is correct only when the override really is `claude`.
/// When it was `/usr/bin/env`, the argv `-p --model …` reached env as its own
/// flags. These tests pin both halves: the argv arrives intact at a real
/// `claude`, and a wrapper is refused before any process is launched.
final class ClaudeCLITransportExecutableGuardTests: XCTestCase {

    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-transport-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// A stub named exactly `claude` that records its argv NUL-delimited.
    private func makeClaudeStub(in directory: URL, argsFile: URL) throws -> URL {
        let stub = directory.appendingPathComponent("claude")
        let script = """
        #!/bin/bash
        printf '%s\\0' "$@" > "\(argsFile.path)"
        printf '{"result":"OK","is_error":false}'
        """
        try script.write(to: stub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)
        return stub
    }

    private func request() -> GenerationTransportRequest {
        GenerationTransportRequest(
            model: "claude-sonnet-5",
            prompt: "PROMPT",
            systemPrompt: "SYS",
            temperature: 0.0,
            maxTokens: 16
        )
    }

    func testArgvReachesTheActualClaudeBinaryUnmodified() async throws {
        let dir = try makeDirectory()
        let argsFile = dir.appendingPathComponent("argv.txt")
        _ = try makeClaudeStub(in: dir, argsFile: argsFile)

        let transport = ClaudeCLITransport(
            model: "claude-sonnet-5",
            executablePath: dir.appendingPathComponent("claude").path
        )
        let response = try await transport.send(request())
        XCTAssertEqual(response.text, "OK")

        let raw = try Data(contentsOf: argsFile)
        let argv = String(decoding: raw, as: UTF8.self)
            .split(separator: "\0", omittingEmptySubsequences: true).map(String.init)

        // Exactly the Claude argv contract — no wrapper subcommand, nothing dropped.
        XCTAssertEqual(
            argv,
            ClaudeCLITransport.buildArgs(
                model: "claude-sonnet-5", systemPrompt: "SYS", prompt: "PROMPT")
        )
        XCTAssertEqual(argv.first, "-p", "the flag env used to reject as its own")
        XCTAssertFalse(argv.contains("claude"), "the binary is claude; it is not an argument")
    }

    func testWrapperOverrideIsRefusedBeforeAnyProcessLaunches() async throws {
        let dir = try makeDirectory()
        let marker = dir.appendingPathComponent("launched.txt")
        // A stub named `env` that would record having run, if it ever ran.
        let wrapper = dir.appendingPathComponent("env")
        try "#!/bin/bash\ntouch \"\(marker.path)\"\n"
            .write(to: wrapper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: wrapper.path)

        let transport = ClaudeCLITransport(model: "claude-sonnet-5", executablePath: wrapper.path)
        do {
            _ = try await transport.send(request())
            XCTFail("a wrapper override must not be launched")
        } catch let error as ClaudeExecutableResolver.ResolutionError {
            guard case .notClaude(_, let basename) = error else {
                return XCTFail("expected .notClaude, got \(error)")
            }
            XCTAssertEqual(basename, "env")
        }

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: marker.path),
            "no process may be launched when resolution fails"
        )
    }

    func testMissingOverrideFailsBeforeLaunch() async throws {
        let dir = try makeDirectory()
        let transport = ClaudeCLITransport(
            model: "claude-sonnet-5",
            executablePath: dir.appendingPathComponent("claude").path
        )
        do {
            _ = try await transport.send(request())
            XCTFail("a missing executable must not reach Process.run()")
        } catch is ClaudeExecutableResolver.ResolutionError {
            // expected
        }
    }
}
