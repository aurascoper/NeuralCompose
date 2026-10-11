import BCICloudBridge
import XCTest
@testable import DialecticSession

/// The headless counterpart to `RuntimeReadiness`'s configured/ready split.
///
/// `RuntimeReport.verify` returned `(promptLoaded, true, true)` for Claude
/// while its own comment said no call had been made, so `--dry-run` printed
/// `transport reachable: yes`, `model available: yes`, `✓ transport reachable`
/// and `✓ model exists` on evidence it had never collected. The app path was
/// corrected first; this pins the harness, which is the surface an operator
/// reads when there is no UI.
///
/// The wording is asserted through `verificationLines` / `dryRunSummaryLines`
/// rather than by capturing stdout. Formatting inline at two `main.swift` call
/// sites is exactly why nothing could assert on these claims before.
final class RuntimeVerificationTests: XCTestCase {

    // MARK: - Fixtures

    /// A PATH holding a stub executable named `claude`. Resolution validates
    /// the file and never runs it — enough to construct the runtime, and never
    /// enough to verify the provider.
    private func claudeEnvironment() throws -> [String: String] {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("runtime-verify-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }

        let claude = dir.appendingPathComponent("claude")
        try "#!/bin/bash\nexit 0\n".write(to: claude, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: claude.path)
        return ["PATH": dir.path]
    }

    private func verifyClaude() throws -> RuntimeVerification {
        let resolved = try RuntimeFactory.make(
            runtimeName: "claude",
            model: "claude-sonnet-5",
            environment: try claudeEnvironment()
        )
        return RuntimeReport.verify(resolved: resolved)
    }

    /// What a reachable daemon holding the exact requested model produces.
    /// Constructed directly rather than probed: the Ollama branch of `verify`
    /// needs a live daemon, and these assertions are about how a fully
    /// verified result is *reported*.
    private let verifiedOllama = RuntimeVerification(
        prompt: .passed, transport: .passed, model: .passed)

    // MARK: - Claude reports absence of evidence, not evidence

    func testClaudeDryRunLeavesProviderAndModelNotChecked() throws {
        let v = try verifyClaude()

        XCTAssertEqual(v.prompt, .passed, "the prompt check is real and does run")
        XCTAssertEqual(v.transport, .notChecked)
        XCTAssertEqual(v.model, .notChecked)
        XCTAssertEqual(v.notCheckedReason, "no generation request made")
    }

    func testClaudeDryRunNeverPrintsTransportReachableYes() throws {
        let lines = RuntimeReport.verificationLines(try verifyClaude())
        let block = lines.joined(separator: "\n")

        let provider = try XCTUnwrap(lines.first { $0.contains("provider reachable") })
        XCTAssertFalse(provider.contains("yes"), provider)
        XCTAssertTrue(provider.contains("not checked"), provider)
        XCTAssertTrue(provider.contains("no generation request made"), provider)

        // The old wording, in either of its two forms.
        XCTAssertFalse(block.contains("transport reachable: yes"), block)
        XCTAssertFalse(block.contains("model available:     yes"), block)
    }

    func testClaudeDryRunNeverPrintsModelExists() throws {
        let summary = RuntimeReport.dryRunSummaryLines(try verifyClaude())
        let block = summary.joined(separator: "\n")

        XCTAssertFalse(block.contains("✓ exact model present"), block)
        XCTAssertFalse(block.contains("✓ model exists"), block)
        XCTAssertFalse(block.contains("✓ endpoint reachable"), block)
        XCTAssertFalse(block.contains("✓ transport reachable"), block)

        // What it must say instead: the gap, named.
        XCTAssertTrue(
            block.contains("– provider and model were not operationally verified"), block)
        // The checks that did run keep their ticks.
        XCTAssertTrue(block.contains("✓ runtime configured"), block)
        XCTAssertTrue(block.contains("✓ prompt loaded"), block)
    }

    // MARK: - Ollama keeps its earned claims

    func testOllamaDryRunReportsEndpointAndExactModelVerified() {
        let lines = RuntimeReport.verificationLines(verifiedOllama).joined(separator: "\n")
        XCTAssertTrue(lines.contains("provider reachable:   yes"), lines)
        XCTAssertTrue(lines.contains("exact model present:  yes"), lines)
        XCTAssertFalse(lines.contains("not checked"), lines)

        let summary = RuntimeReport.dryRunSummaryLines(verifiedOllama).joined(separator: "\n")
        XCTAssertTrue(summary.contains("✓ endpoint reachable"), summary)
        XCTAssertTrue(summary.contains("✓ exact model present"), summary)
        XCTAssertFalse(summary.contains("not operationally verified"), summary)
    }

    // MARK: - notChecked is not failure

    func testNotCheckedDoesNotFailConfigurationOnlyDryRun() throws {
        XCTAssertFalse(try verifyClaude().hasFailure, "an unrun check must not fail the run")
        XCTAssertFalse(verifiedOllama.hasFailure)

        // A check that actually ran and did not hold still fails, so relaxing
        // the exit condition has not made it unconditional.
        XCTAssertTrue(
            RuntimeVerification(prompt: .passed, transport: .failed, model: .notChecked)
                .hasFailure)
        XCTAssertTrue(
            RuntimeVerification(prompt: .failed, transport: .notChecked, model: .notChecked)
                .hasFailure)
    }
}
