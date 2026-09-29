import XCTest
import Foundation
import os
@testable import BCICore

/// Tests for the `GenerationRuntime` protocol surface.
///
/// Level 1 of the test rings: a test conformer that implements BOTH
/// `TextGenerating` (legacy) and `GenerationRuntime` (new) on the
/// same instance, and asserts the two protocol methods produce
/// byte-equivalent output. The keep-bar from seed-004 says the
/// refactor must not change behavior; this test is the type-level
/// proof of that claim.
final class GenerationRuntimeProtocolTests: XCTestCase {

    /// A test conformer that records every call. Implements both
    /// `TextGenerating` and `GenerationRuntime` against a fixed
    /// response so the two protocol methods produce identical text
    /// (the only intentional difference is the `metadata` and
    /// `latencyMilliseconds` fields the new protocol exposes).
    ///
    /// Class (not struct) because the protocol methods mutate
    /// `textGeneratingCalls` / `generationRuntimeCalls` for the
    /// recording assertion. `NSLock` is unavailable from async
    /// contexts under strict concurrency, so the recording arrays
    /// are protected by `OSAllocatedUnfairLock` (Apple's async-safe
    /// lock primitive).
    private final class DualConformantRuntime: TextGenerating, GenerationRuntime, @unchecked Sendable {
        let isLive = true
        let modelIdentifier = "test-model"
        let runtimeName = "test-runtime"
        let capabilities = RuntimeCapabilities()
        let cannedResponse: String

        private let textGeneratingCallsLock = OSAllocatedUnfairLock<[(prompt: String, maxTokens: Int, temperature: Double, id: UUID)]>(initialState: [])
        private let generationRuntimeCallsLock = OSAllocatedUnfairLock<[(prompt: String, context: GenerationContext)]>(initialState: [])

        var textGeneratingCalls: [(prompt: String, maxTokens: Int, temperature: Double, id: UUID)] {
            textGeneratingCallsLock.withLock { $0 }
        }
        var generationRuntimeCalls: [(prompt: String, context: GenerationContext)] {
            generationRuntimeCallsLock.withLock { $0 }
        }

        init(cannedResponse: String) {
            self.cannedResponse = cannedResponse
        }

        func generate(
            prompt: String,
            maxTokens: Int,
            temperature: Double,
            cancellationID: UUID
        ) async throws -> String {
            textGeneratingCallsLock.withLock { $0.append((prompt, maxTokens, temperature, cancellationID)) }
            return cannedResponse
        }

        func generate(
            prompt: String,
            context: GenerationContext
        ) async throws -> GenerationResult {
            generationRuntimeCallsLock.withLock { $0.append((prompt, context)) }
            return GenerationResult(
                text: cannedResponse,
                metadata: GenerationMetadata(
                    runtime: runtimeName,
                    transport: "test-transport",
                    provider: "test-provider",
                    model: "test-model",
                    promptHash: "test-hash",
                    promptProfile: "test-profile",
                    interactionStyle: "test-style"
                )
            )
        }
    }

    func testProtocolEquivalenceTextMatches() async throws {
        let r = DualConformantRuntime(cannedResponse: "Hello, world.")
        let legacyText = try await r.generate(
            prompt: "hi",
            maxTokens: 64,
            temperature: 0.4,
            cancellationID: UUID()
        )
        let newResult = try await r.generate(
            prompt: "hi",
            context: GenerationContext(generationParameters: .init(temperature: 0.4, maxTokens: 64))
        )
        XCTAssertEqual(legacyText, newResult.text, "TextGenerating and GenerationRuntime must produce identical text")
    }

    func testProtocolEquivalencePromptIsRecorded() async throws {
        let r = DualConformantRuntime(cannedResponse: "ok")
        _ = try await r.generate(prompt: "p1", maxTokens: 8, temperature: 0.0, cancellationID: UUID())
        _ = try await r.generate(
            prompt: "p1",
            context: GenerationContext()
        )
        XCTAssertEqual(r.textGeneratingCalls.count, 1)
        XCTAssertEqual(r.textGeneratingCalls.first?.prompt, "p1")
        XCTAssertEqual(r.generationRuntimeCalls.count, 1)
        XCTAssertEqual(r.generationRuntimeCalls.first?.prompt, "p1")
    }

    func testProtocolEquivalenceParametersAreRecorded() async throws {
        let r = DualConformantRuntime(cannedResponse: "ok")
        _ = try await r.generate(prompt: "p", maxTokens: 128, temperature: 0.7, cancellationID: UUID())
        _ = try await r.generate(
            prompt: "p",
            context: GenerationContext(generationParameters: .init(temperature: 0.7, maxTokens: 128))
        )
        let legacy = r.textGeneratingCalls.first!
        let newCtx = r.generationRuntimeCalls.first!.context
        XCTAssertEqual(legacy.maxTokens, newCtx.generationParameters.maxTokens)
        XCTAssertEqual(legacy.temperature, newCtx.generationParameters.temperature ?? 0.0, accuracy: 0.0001)
    }

    func testGenerationResultCarriesMetadata() async throws {
        let r = DualConformantRuntime(cannedResponse: "ok")
        let result = try await r.generate(prompt: "p", context: GenerationContext())
        XCTAssertEqual(result.text, "ok")
        XCTAssertEqual(result.metadata.runtime, "test-runtime")
        XCTAssertEqual(result.metadata.transport, "test-transport")
        XCTAssertEqual(result.metadata.provider, "test-provider")
        XCTAssertEqual(result.metadata.model, "test-model")
        XCTAssertEqual(result.metadata.promptHash, "test-hash")
        XCTAssertEqual(result.metadata.promptProfile, "test-profile")
        XCTAssertEqual(result.metadata.interactionStyle, "test-style")
    }

    func testRuntimeCapabilitiesAdvertised() {
        let r = DualConformantRuntime(cannedResponse: "ok")
        XCTAssertFalse(r.capabilities.tokenCounting)
        XCTAssertFalse(r.capabilities.streaming)
        XCTAssertFalse(r.capabilities.logProbs)
        XCTAssertEqual(r.capabilities, RuntimeCapabilities.none)
    }

    func testGenerationContextEmptyHasNoPriorTurns() {
        let ctx = GenerationContext.empty
        XCTAssertTrue(ctx.priorTurns.isEmpty)
        XCTAssertTrue(ctx.modelHints.isEmpty)
        XCTAssertNil(ctx.generationParameters.temperature)
        XCTAssertNil(ctx.generationParameters.maxTokens)
    }

    func testGenerationContextPriorTurnsRoundTrip() {
        let turns = [
            GenerationContext.Turn(role: .user, text: "u1"),
            GenerationContext.Turn(role: .assistant, text: "a1"),
        ]
        let ctx = GenerationContext(priorTurns: turns)
        XCTAssertEqual(ctx.priorTurns, turns)
    }

    func testGenerationMetadataIsEquatable() {
        let a = GenerationMetadata(
            runtime: "r", transport: "t", provider: "p", model: "m",
            promptHash: "h", promptProfile: "pp", interactionStyle: "is"
        )
        let b = GenerationMetadata(
            runtime: "r", transport: "t", provider: "p", model: "m",
            promptHash: "h", promptProfile: "pp", interactionStyle: "is"
        )
        XCTAssertEqual(a, b)
    }

    func testRuntimeNameIsDistinctFromModel() {
        // The runtime / transport / provider / model quadruple must
        // each be independently settable; the keep-bar requires that
        // model-as-configuration work, so a runtime like
        // `claude-cli` can carry model `claude-sonnet-5` or
        // `claude-opus-5` without renaming the type.
        let r = DualConformantRuntime(cannedResponse: "ok")
        XCTAssertEqual(r.runtimeName, "test-runtime")
        XCTAssertEqual(r.modelIdentifier, "test-model")
        XCTAssertNotEqual(r.runtimeName, r.modelIdentifier)
    }
}
