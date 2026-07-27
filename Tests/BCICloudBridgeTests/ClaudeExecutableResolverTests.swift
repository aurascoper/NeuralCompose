import XCTest
@testable import BCICloudBridge

/// Regression tests for the malformed Claude invocation.
///
/// The old resolver returned the first executable file from
/// `["/usr/bin/env", "/usr/local/bin/claude", "/opt/homebrew/bin/claude"]`.
/// `/usr/bin/env` always exists and is always executable, so it always won,
/// and the transport then launched `/usr/bin/env -p --model …` — env rejects
/// `-p` as one of its own flags. The default harness runtime was non-functional.
///
/// Every failure below is a *typed error raised before any Process is launched*.
final class ClaudeExecutableResolverTests: XCTestCase {

    // MARK: - Fixtures

    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-resolver-\(UUID().uuidString)")
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

    // MARK: - Explicit path

    func testExplicitValidClaudeExecutableResolves() throws {
        let dir = try makeDirectory()
        let claude = try makeExecutable(named: "claude", in: dir)
        let resolved = try ClaudeExecutableResolver.resolve(explicitPath: claude.path, environment: [:])
        XCTAssertEqual(resolved, claude.path)
    }

    func testExplicitMissingPathThrowsBeforeLaunch() throws {
        let dir = try makeDirectory()
        let absent = dir.appendingPathComponent("claude").path
        XCTAssertThrowsError(
            try ClaudeExecutableResolver.resolve(explicitPath: absent, environment: [:])
        ) { error in
            XCTAssertEqual(
                error as? ClaudeExecutableResolver.ResolutionError,
                .explicitPathMissing(absent)
            )
        }
    }

    /// An empty configured value is a misconfiguration. Falling back to PATH
    /// here would be precisely the silent substitution this type exists to
    /// prevent — and it is the same class of bug as the original defect.
    func testEmptyExplicitPathIsAHardErrorNotAPathFallback() throws {
        let pathDir = try makeDirectory()
        try makeExecutable(named: "claude", in: pathDir)

        XCTAssertThrowsError(
            try ClaudeExecutableResolver.resolve(
                explicitPath: "",
                environment: ["PATH": pathDir.path]
            ),
            "an empty configured path must not silently resolve via PATH"
        ) { error in
            guard case .explicitPathMissing? =
                error as? ClaudeExecutableResolver.ResolutionError else {
                return XCTFail("expected .explicitPathMissing, got \(error)")
            }
        }
    }

    /// An explicit path is used exclusively — no PATH fallback — so a
    /// misconfiguration is a hard error, never a silent substitution.
    func testExplicitPathDoesNotFallBackToPath() throws {
        let pathDir = try makeDirectory()
        try makeExecutable(named: "claude", in: pathDir)
        let absent = try makeDirectory().appendingPathComponent("claude").path

        XCTAssertThrowsError(
            try ClaudeExecutableResolver.resolve(
                explicitPath: absent,
                environment: ["PATH": pathDir.path]
            )
        )
    }

    // MARK: - The defect itself

    func testUsrBinEnvIsRejectedAsTheClaudeExecutable() throws {
        XCTAssertTrue(
            FileManager.default.isExecutableFile(atPath: "/usr/bin/env"),
            "precondition: /usr/bin/env is executable, which is why it used to win"
        )
        XCTAssertThrowsError(
            try ClaudeExecutableResolver.resolve(explicitPath: "/usr/bin/env", environment: [:])
        ) { error in
            guard case .notClaude(_, let basename)? =
                error as? ClaudeExecutableResolver.ResolutionError else {
                return XCTFail("expected .notClaude, got \(error)")
            }
            XCTAssertEqual(basename, "env")
        }
    }

    func testEnvOnPathIsNotMistakenForClaude() throws {
        // A PATH containing /usr/bin (hence env) but no claude must fail,
        // not silently resolve to the wrapper.
        XCTAssertThrowsError(
            try ClaudeExecutableResolver.resolve(environment: ["PATH": "/usr/bin"])
        ) { error in
            guard case .notFoundOnPath? =
                error as? ClaudeExecutableResolver.ResolutionError else {
                return XCTFail("expected .notFoundOnPath, got \(error)")
            }
        }
    }

    func testAnyWrapperNameIsRejected() throws {
        let dir = try makeDirectory()
        for name in ["env", "sh", "claude-wrapper", "claude.sh"] {
            let wrapper = try makeExecutable(named: name, in: dir)
            XCTAssertThrowsError(
                try ClaudeExecutableResolver.resolve(explicitPath: wrapper.path, environment: [:]),
                "\(name) must not be accepted as the Claude CLI"
            )
        }
    }

    // MARK: - PATH search

    func testPathDiscoveredClaudeResolves() throws {
        let dir = try makeDirectory()
        let claude = try makeExecutable(named: "claude", in: dir)
        let resolved = try ClaudeExecutableResolver.resolve(environment: ["PATH": dir.path])
        XCTAssertEqual(resolved, claude.path)
    }

    func testPathSearchRespectsOrder() throws {
        let first = try makeDirectory()
        let second = try makeDirectory()
        let winner = try makeExecutable(named: "claude", in: first)
        try makeExecutable(named: "claude", in: second)
        let resolved = try ClaudeExecutableResolver.resolve(
            environment: ["PATH": "\(first.path):\(second.path)"]
        )
        XCTAssertEqual(resolved, winner.path, "the earliest PATH entry must win")
    }

    /// A PATH entry holding an unusable `claude` is skipped, not fatal —
    /// that is how PATH resolution is expected to behave.
    func testUnusableEntryIsSkippedAndSearchContinues() throws {
        let bad = try makeDirectory()
        let good = try makeDirectory()
        // Non-executable file named `claude`.
        try "not executable".write(
            to: bad.appendingPathComponent("claude"), atomically: true, encoding: .utf8)
        let claude = try makeExecutable(named: "claude", in: good)

        let resolved = try ClaudeExecutableResolver.resolve(
            environment: ["PATH": "\(bad.path):\(good.path)"]
        )
        XCTAssertEqual(resolved, claude.path)
    }

    func testEmptyOrAbsentPathThrows() throws {
        for environment in [[:], ["PATH": ""]] as [[String: String]] {
            XCTAssertThrowsError(try ClaudeExecutableResolver.resolve(environment: environment))
        }
    }

    // MARK: - Symlinks

    /// Homebrew and npm expose commands as symlinks (`/opt/homebrew/bin/claude`
    /// → `../Cellar/…/claude`), so rejecting symlinks would reject the most
    /// common real installation. The invocation basename is what must be
    /// `claude`; file and executable checks follow the link.
    func testSymlinkNamedClaudeIsAccepted() throws {
        let targetDir = try makeDirectory()
        let linkDir = try makeDirectory()
        let target = try makeExecutable(named: "claude-0.4.2", in: targetDir)
        let link = linkDir.appendingPathComponent("claude")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let resolved = try ClaudeExecutableResolver.resolve(explicitPath: link.path, environment: [:])
        XCTAssertEqual(
            resolved, link.path,
            "the invocation path must be preserved for Process.executableURL, not the link target"
        )
    }

    func testSymlinkNamedClaudeIsDiscoverableOnPath() throws {
        let targetDir = try makeDirectory()
        let binDir = try makeDirectory()
        let target = try makeExecutable(named: "claude-real", in: targetDir)
        let link = binDir.appendingPathComponent("claude")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let resolved = try ClaudeExecutableResolver.resolve(environment: ["PATH": binDir.path])
        XCTAssertEqual(resolved, link.path)
    }

    func testBrokenSymlinkNamedClaudeIsRejected() throws {
        let dir = try makeDirectory()
        let link = dir.appendingPathComponent("claude")
        try FileManager.default.createSymbolicLink(
            at: link,
            withDestinationURL: dir.appendingPathComponent("absent-target")
        )
        XCTAssertThrowsError(
            try ClaudeExecutableResolver.resolve(explicitPath: link.path, environment: [:]),
            "a dangling symlink is not a runnable Claude"
        )
    }

    func testSymlinkWithNonClaudeInvocationNameIsRejected() throws {
        let targetDir = try makeDirectory()
        let linkDir = try makeDirectory()
        let target = try makeExecutable(named: "claude", in: targetDir)
        let link = linkDir.appendingPathComponent("cl")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        XCTAssertThrowsError(
            try ClaudeExecutableResolver.resolve(explicitPath: link.path, environment: [:])
        ) { error in
            guard case .notClaude(_, let basename)? =
                error as? ClaudeExecutableResolver.ResolutionError else {
                return XCTFail("expected .notClaude, got \(error)")
            }
            XCTAssertEqual(basename, "cl", "the invocation name decides, not the target's name")
        }
    }

    func testSymlinkToDirectoryIsRejected() throws {
        let targetDir = try makeDirectory()
        let linkDir = try makeDirectory()
        let link = linkDir.appendingPathComponent("claude")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: targetDir)

        XCTAssertThrowsError(
            try ClaudeExecutableResolver.validate(link.path)
        ) { error in
            XCTAssertEqual(
                error as? ClaudeExecutableResolver.ResolutionError, .notAFile(link.path))
        }
    }

    func testSymlinkToNonExecutableTargetIsRejected() throws {
        let targetDir = try makeDirectory()
        let linkDir = try makeDirectory()
        let target = targetDir.appendingPathComponent("payload")
        try "not executable".write(to: target, atomically: true, encoding: .utf8)
        let link = linkDir.appendingPathComponent("claude")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        XCTAssertThrowsError(try ClaudeExecutableResolver.validate(link.path)) { error in
            XCTAssertEqual(
                error as? ClaudeExecutableResolver.ResolutionError, .notExecutable(link.path))
        }
    }

    // MARK: - Validation

    func testDirectoryNamedClaudeIsRejected() throws {
        let dir = try makeDirectory()
        let asDirectory = dir.appendingPathComponent("claude")
        try FileManager.default.createDirectory(at: asDirectory, withIntermediateDirectories: true)
        XCTAssertThrowsError(
            try ClaudeExecutableResolver.validate(asDirectory.path)
        ) { error in
            XCTAssertEqual(
                error as? ClaudeExecutableResolver.ResolutionError, .notAFile(asDirectory.path))
        }
    }

    func testNonExecutableClaudeIsRejected() throws {
        let dir = try makeDirectory()
        let file = dir.appendingPathComponent("claude")
        try "text".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try ClaudeExecutableResolver.validate(file.path)) { error in
            XCTAssertEqual(
                error as? ClaudeExecutableResolver.ResolutionError, .notExecutable(file.path))
        }
    }

    func testSearchPathsPreserveOrderAndDropEmptyEntries() {
        XCTAssertEqual(
            ClaudeExecutableResolver.searchPaths(in: ["PATH": "/a::/b:/c"]),
            ["/a", "/b", "/c"]
        )
        XCTAssertEqual(ClaudeExecutableResolver.searchPaths(in: [:]), [])
    }
}
