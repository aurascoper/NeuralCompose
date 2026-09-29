import XCTest
import Foundation
import os
@testable import BCICloudBridge
@testable import BCICore

/// Tests for `GenerationRuntimeTextGeneratingAdapter` — the
/// `TextGenerating` seam that wraps a `GenerationRuntime` so the
/// legacy dialectic loop can consume it. Specifically: the
/// `MetadataPublishingTextGenerating` refinement the adapter conforms
/// to, which lets the loop capture `GenerationMetadata` for the
/// `DialecticalTurnEvent.generatorFingerprint` field without
/// breaking the `String`-typed legacy seam.
///
/// The contract: every call to `generate(prompt:...)` invokes the
/// `onMetadata` callback exactly once with the metadata from the
/// underlying `GenerationRuntime.generate(...)` call. The callback
/// runs synchronously on the same task. The returned `String` is
/// the `text` field of the `GenerationResult`.
final class GenerationRuntimeTextGeneratingAdapterTests: XCTestCase {

    // MARK: - Helpers

    /// A minimal `GenerationRuntime` conformer that returns a
    /// pre-canned `GenerationResult` for every `generate(...)` call.
    /// Records the calls it received so the test can assert on
    /// prompt construction (the system-prompt + user-prompt
    /// composition in the `GenerationContext`).
    private final class StubRuntime: GenerationRuntime, @unchecked Sendable {
        let runtimeName: String
        let modelIdentifier: String
        let isLive: Bool
        let capabilities: RuntimeCapabilities
        let result: GenerationResult
        private let counter = OSAllocatedUnfairLock<Int>(initialState: 0)
        var callCount: Int { counter.withLock { $0 } }
        private let contextLock = OSAllocatedUnfairLock<GenerationContext?>(initialState: Optional<GenerationContext>.none)
        var lastContext: GenerationContext? { contextLock.withLock { $0 } }

        init(result: GenerationResult) {
            self.runtimeName = "stub"
            self.modelIdentifier = result.metadata.model
            self.isLive = false
            self.capabilities = RuntimeCapabilities(tokenCounting: false, streaming: false, logProbs: false)
            self.result = result
        }

        func generate(prompt: String, context: GenerationContext) async throws -> GenerationResult {
            counter.withLock { $0 += 1 }
            contextLock.withLock { $0 = context }
            return result
        }
    }

    private static let stubMetadata = GenerationMetadata(
        runtime: "stub",
        transport: "in-process",
        provider: "test",
        model: "test-model",
        promptHash: "abc123",
        promptProfile: "wakingDialectical",
        interactionStyle: "dialectic",
        generationParameters: ["temperature": 0.7, "maxTokens": 256.0],
        latencyMilliseconds: 42,
        tokenCount: 17
    )

    private static let stubResult = GenerationResult(
        text: "stub-response-text",
        metadata: stubMetadata
    )

    // MARK: - Tests

    func testGenerateReturnsTextField() async throws {
        let runtime = StubRuntime(result: Self.stubResult)
        let adapter = GenerationRuntimeTextGeneratingAdapter(
            runtime: runtime,
            maxTokens: 256,
            defaultTemperature: 0.7
        )
        let text = try await adapter.generate(
            prompt: "user",
            maxTokens: 256,
            temperature: 0.7,
            cancellationID: UUID()
        )
        XCTAssertEqual(text, "stub-response-text")
    }

    func testOnMetadataFiresWithRuntimeMetadata() async throws {
        let runtime = StubRuntime(result: Self.stubResult)
        var adapter = GenerationRuntimeTextGeneratingAdapter(
            runtime: runtime,
            maxTokens: 256,
            defaultTemperature: 0.7
        )
        let metadataExpectation = expectation(description: "metadata callback fired")
        let capturedBox = CapturedMetadataBox()
        adapter.onMetadata = { (metadata: GenerationMetadata) in
            capturedBox.value = metadata
            metadataExpectation.fulfill()
        }
        _ = try await adapter.generate(
            prompt: "user",
            maxTokens: 256,
            temperature: 0.7,
            cancellationID: UUID()
        )
        await fulfillment(of: [metadataExpectation], timeout: 1)
        XCTAssertEqual(capturedBox.value, Self.stubMetadata)
    }

    func testOnMetadataFiresOncePerCall() async throws {
        let runtime = StubRuntime(result: Self.stubResult)
        var adapter = GenerationRuntimeTextGeneratingAdapter(
            runtime: runtime,
            maxTokens: 256,
            defaultTemperature: 0.7
        )
        let fireCountBox = CapturedIntBox()
        adapter.onMetadata = { (_: GenerationMetadata) in
            fireCountBox.value += 1
        }
        for _ in 0..<3 {
            _ = try await adapter.generate(
                prompt: "user",
                maxTokens: 256,
                temperature: 0.7,
                cancellationID: UUID()
            )
        }
        XCTAssertEqual(fireCountBox.value, 3)
        XCTAssertEqual(runtime.callCount, 3)
    }

    func testAdapterConformsToMetadataPublishingProtocol() {
        // The dialectic loop type-checks for `MetadataPublishingTextGenerating`
        // before wiring the callback. If the adapter loses the conformance,
        // the loop's `attachMetadataCaptureFromAdapter()` becomes a no-op
        // silently. Pin the conformance with a compile-time check.
        let runtime = StubRuntime(result: Self.stubResult)
        let adapter = GenerationRuntimeTextGeneratingAdapter(
            runtime: runtime
        )
        let publisher: MetadataPublishingTextGenerating = adapter
        XCTAssertNotNil(publisher as AnyObject)
    }

    func testNoCallbackFiresWhenOnMetadataIsNil() async throws {
        // The legacy `TextGenerating` callers (e.g. the harness
        // before the metadata-thread commit) leave `onMetadata`
        // unset. The adapter must still return text and not
        // crash on the nil callback.
        let runtime = StubRuntime(result: Self.stubResult)
        let adapter = GenerationRuntimeTextGeneratingAdapter(
            runtime: runtime
        )
        XCTAssertNil(adapter.onMetadata)
        let text = try await adapter.generate(
            prompt: "user",
            maxTokens: 256,
            temperature: 0.7,
            cancellationID: UUID()
        )
        XCTAssertEqual(text, "stub-response-text")
    }

    /// The bug this test catches: when a struct-typed
    /// `MetadataPublishingTextGenerating` is held in an
    /// existential box (`any TextGenerating`) and the consumer
    /// mutates `onMetadata` through a local `var` cast from
    /// `as?`, the mutation must propagate to the original
    /// stored copy. The `MetadataCallbackBox` pattern (a
    /// class-typed storage shared across all struct copies) is
    /// what makes this work. If the box is reverted to a
    /// struct-typed property, this test will fail because the
    /// `var publisher = existential as? Protocol` cast opens
    /// the box into a local copy whose mutation doesn't reach
    /// the original.
    func testOnMetadataPropagatesAcrossExistentialCopy() async throws {
        let runtime = StubRuntime(result: Self.stubResult)
        let adapter = GenerationRuntimeTextGeneratingAdapter(
            runtime: runtime
        )

        // The dialectic loop stores the generator as
        // `let generator: any TextGenerating`. Simulate that
        // here: wrap the adapter in an existential, then cast
        // back to a `var` to mutate the callback. The runtime
        // call that follows must see the new callback.
        let existential: any TextGenerating = adapter
        var publisher = existential as? MetadataPublishingTextGenerating
        XCTAssertNotNil(publisher, "adapter must conform to the refinement")

        let fireBox = CapturedIntBox()
        publisher?.onMetadata = { (_: GenerationMetadata) in
            fireBox.value += 1
        }

        _ = try await existential.generate(
            prompt: "user",
            maxTokens: 256,
            temperature: 0.7,
            cancellationID: UUID()
        )

        XCTAssertEqual(
            fireBox.value, 1,
            "callback set on the local cast must propagate to the original existential copy"
        )
    }
}

// MARK: - Test helpers (sendable boxes so the @Sendable closure can mutate them)

private final class CapturedMetadataBox: @unchecked Sendable {
    var value: GenerationMetadata?
}

private final class CapturedIntBox: @unchecked Sendable {
    var value: Int = 0
}
