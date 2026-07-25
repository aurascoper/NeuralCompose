import BCICloudBridge
import XCTest
@testable import DialecticSession

/// Pins the R2 **call site**, not just the resolver.
///
/// This exists because the first version of these tests did not. Reverting
/// `makeClaude` to the old `resolveClaudeCLI()` helper — the one that returned
/// `/usr/bin/env` — left all 93 BCICloudBridge tests green, because they
/// exercise `ClaudeExecutableResolver` in isolation and never touch the
/// defective caller. A mutation confirmed it. These tests fail if the call site
/// regresses.
final class RuntimeFactoryClaudeResolutionTests: XCTestCase {

    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("runtime-factory-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    @discardableResult
    private func makeExecutable(named name: String, in directory: URL) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try "#!/bin/bash\nexit 0\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    /// The exact regression: a PATH containing `/usr/bin` — hence `env` — but
    /// no `claude`. The old helper returned `/usr/bin/env` here and the harness
    /// went on to launch `env -p --model …`. Resolution must now fail instead.
    func testClaudeRuntimeFailsWhenOnlyEnvIsAvailable() throws {
        XCTAssertTrue(
            FileManager.default.isExecutableFile(atPath: "/usr/bin/env"),
            "precondition: /usr/bin/env is executable, which is why it used to win")

        XCTAssertThrowsError(
            try RuntimeFactory.make(
                runtimeName: "claude",
                model: "claude-sonnet-5",
                environment: ["PATH": "/usr/bin"]
            )
        ) { error in
            // Pattern-match rather than add Equatable to a production error
            // type purely for a test assertion.
            guard case RuntimeFactoryError.claudeCLINotFound = error else {
                return XCTFail("expected .claudeCLINotFound (the install hint), got \(error)")
            }
        }
    }

    func testClaudeRuntimeFailsOnEmptyPath() throws {
        XCTAssertThrowsError(
            try RuntimeFactory.make(
                runtimeName: "claude", model: "claude-sonnet-5", environment: ["PATH": ""])
        )
    }

    /// The positive half: a real `claude` on PATH resolves, and the resolved
    /// runtime is the one that was requested.
    func testClaudeRuntimeResolvesWhenClaudeIsOnPath() throws {
        let dir = try makeDirectory()
        try makeExecutable(named: "claude", in: dir)

        let resolved = try RuntimeFactory.make(
            runtimeName: "claude",
            model: "claude-sonnet-5",
            environment: ["PATH": dir.path]
        )
        XCTAssertEqual(resolved.promptProfile, .wakingDialectical)
        XCTAssertFalse(resolved.systemPrompt.isEmpty, "a constraining prompt must be loaded")
    }

    /// `env` sitting earlier on PATH must not win over a later real `claude`.
    func testEnvEarlierOnPathDoesNotShadowARealClaude() throws {
        let dir = try makeDirectory()
        try makeExecutable(named: "claude", in: dir)

        XCTAssertNoThrow(
            try RuntimeFactory.make(
                runtimeName: "claude",
                model: "claude-sonnet-5",
                environment: ["PATH": "/usr/bin:\(dir.path)"]
            )
        )
    }

    func testUnknownRuntimeStillThrows() throws {
        XCTAssertThrowsError(
            try RuntimeFactory.make(runtimeName: "olama", model: "m", environment: ["PATH": "/usr/bin"])
        ) { error in
            guard case RuntimeFactoryError.unknownRuntime(let name) = error else {
                return XCTFail("expected .unknownRuntime, got \(error)")
            }
            XCTAssertEqual(name, "olama")
        }
    }
}
