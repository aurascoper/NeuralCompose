import BCICore
import XCTest
@testable import BCICloudBridge

/// `LiveRuntimeFactory` is the app's runtime-resolution seam. It must either
/// return the runtime that was requested, or throw — never substitute.
///
/// The defect this guards: `AppViewModel` used to write
/// `(try? LiveRuntimeFactory.make(...)) ?? (ClaudeCLIGenerator(...), …)`, so a
/// mistyped `NEURALCOMPOSE_RUNTIME` — set by a user who wanted local-only
/// inference — silently produced cloud egress to Anthropic instead.
final class LiveRuntimeFactoryFailClosedTests: XCTestCase {

    func testUnknownRuntimeThrowsAndConstructsNothing() throws {
        // `olama` is the realistic typo: the user meant local Ollama.
        XCTAssertThrowsError(
            try LiveRuntimeFactory.make(runtimeName: "olama", model: "qwen2.5:0.5b")
        ) { error in
            let message = (error as NSError).localizedDescription
            XCTAssertTrue(
                message.contains("olama"),
                "the error must name the runtime that was actually requested: \(message)"
            )
            XCTAssertTrue(
                message.contains("claude") && message.contains("ollama"),
                "the error should list what is supported: \(message)"
            )
        }
    }

    func testUnknownRuntimeNeverYieldsAClaudeGenerator() throws {
        // A throwing call returns no value at all, which is the property that
        // matters: there is nothing for a caller to fall back onto.
        for typo in ["olama", "Ollamaa", "gpt", "", "  "] {
            XCTAssertThrowsError(
                try LiveRuntimeFactory.make(runtimeName: typo, model: "m"),
                "runtime \(typo.debugDescription) must not resolve"
            )
        }
    }

    func testRequestedClaudeRuntimeStillResolves() throws {
        let (generator, resolved) = try LiveRuntimeFactory.make(
            runtimeName: "claude",
            model: "claude-sonnet-5",
            systemPrompt: "SYS"
        )
        XCTAssertEqual(resolved.name, "claude-cli")
        XCTAssertEqual(resolved.model, "claude-sonnet-5")
        XCTAssertTrue(generator is ClaudeCLIGenerator)
    }

    func testRequestedOllamaRuntimeResolvesToOllamaNotClaude() throws {
        let (generator, resolved) = try LiveRuntimeFactory.make(
            runtimeName: "ollama",
            model: "qwen2.5:0.5b",
            systemPrompt: "SYS"
        )
        XCTAssertEqual(resolved.name, "ollama")
        XCTAssertEqual(resolved.model, "qwen2.5:0.5b")
        XCTAssertFalse(
            generator is ClaudeCLIGenerator,
            "a requested local runtime must never resolve to the cloud generator"
        )
    }

    /// R18 CHARACTERIZATION — records a known gap. This test does NOT
    /// satisfy the "missing model fails closed" acceptance criterion and
    /// must not be counted among the tests that prove it.
    ///
    /// The A1 brief asks for "missing Ollama model disables the loop". That is
    /// true of the *harness* (`RuntimeFactory.makeOllama` probes `/api/tags`
    /// and throws `ollamaModelMissing`), but **not** of the app:
    /// `LiveRuntimeFactory` performs no probe, so an unpulled model resolves
    /// successfully here and only fails later, at generate time.
    ///
    /// This test pins that current behaviour so the gap is visible in code
    /// rather than only in prose. It is deliberately written to FAIL once
    /// probing is added — at which point invert it to assert the throw. That
    /// work belongs with R8, where truthful provider display needs the same
    /// probe result.
    func testAppPathCharacterizationDoesNotProbeOllamaModelAvailability_R18() throws {
        let (_, resolved) = try LiveRuntimeFactory.make(
            runtimeName: "ollama",
            model: "definitely-not-a-pulled-model",
            systemPrompt: "SYS"
        )
        XCTAssertEqual(
            resolved.model,
            "definitely-not-a-pulled-model",
            "resolution currently accepts any model name; see R8 follow-up"
        )
    }

    /// The default is unchanged: absent configuration still means Claude, which
    /// is the pre-existing production behaviour and not a fallback.
    func testDefaultResolutionIsUnchanged() throws {
        let (_, resolved) = try LiveRuntimeFactory.make(
            runtimeName: nil, model: nil, systemPrompt: "SYS")
        XCTAssertEqual(resolved.name, "claude-cli")
        XCTAssertEqual(resolved.model, "claude-sonnet-5")
    }
}
