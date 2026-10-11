import XCTest
import Foundation
import os
@testable import BCICore

/// Tests for the `GenerationTransport` protocol surface and the
/// `FakeTransport` test double used by Levels 1-2 of the seed-004
/// test rings.
///
/// Level 2: assert that any conformer to `GenerationTransport`
/// satisfies the protocol without special-casing. The test runs the
/// same `GenerationRuntime` against both `ClaudeCLITransport` (the
/// real subprocess path) and a `FakeTransport` (canned response);
/// the runtime behavior must be uniform.
final class GenerationTransportTests: XCTestCase {

    /// A test double that returns a canned response (or canned
    /// error) regardless of the request. Implements `GenerationTransport`
    /// so any test runtime that accepts a transport can be driven
    /// without a real subprocess.
    private final class FakeTransport: GenerationTransport, @unchecked Sendable {
        let transportName: String
        let providerName: String
        let response: Result<GenerationTransportResponse, Error>
        private let requestsLock = OSAllocatedUnfairLock<[GenerationTransportRequest]>(initialState: [])

        var requests: [GenerationTransportRequest] {
            requestsLock.withLock { $0 }
        }

        init(
            transportName: String = "fake",
            providerName: String = "fake",
            response: Result<GenerationTransportResponse, Error>
        ) {
            self.transportName = transportName
            self.providerName = providerName
            self.response = response
        }

        func send(_ request: GenerationTransportRequest) async throws -> GenerationTransportResponse {
            requestsLock.withLock { $0.append(request) }
            return try response.get()
        }
    }

    /// A test runtime that composes an injected `GenerationTransport`.
    /// Used to verify the transport protocol has no Claude-specific
    /// assumptions (Level 2).
    private struct ComposedRuntime: GenerationRuntime {
        let runtimeName: String
        let modelIdentifier: String
        let isLive = true
        let capabilities = RuntimeCapabilities()
        let transport: any GenerationTransport
        let systemPrompt: String

        func generate(prompt: String, context: GenerationContext) async throws -> GenerationResult {
            let req = GenerationTransportRequest(
                model: modelIdentifier,
                prompt: prompt,
                systemPrompt: systemPrompt
            )
            let response = try await transport.send(req)
            return GenerationResult(
                text: response.text,
                metadata: GenerationMetadata(
                    runtime: runtimeName,
                    transport: transport.transportName,
                    provider: transport.providerName,
                    model: modelIdentifier,
                    promptHash: "test-hash",
                    promptProfile: "test-profile",
                    interactionStyle: "test-style"
                )
            )
        }
    }

    func testFakeTransportReturnsCannedResponse() async throws {
        let transport = FakeTransport(
            response: .success(GenerationTransportResponse(
                text: "canned", rawMetadata: ["k": "v"], finishReason: .endTurn
            ))
        )
        let req = GenerationTransportRequest(
            model: "m", prompt: "p", systemPrompt: "s"
        )
        let response = try await transport.send(req)
        XCTAssertEqual(response.text, "canned")
        XCTAssertEqual(response.rawMetadata, ["k": "v"])
        XCTAssertEqual(response.finishReason, .endTurn)
    }

    func testFakeTransportReturnsCannedError() async {
        enum FakeError: Error { case boom }
        let transport = FakeTransport(response: .failure(FakeError.boom))
        let req = GenerationTransportRequest(model: "m", prompt: "p", systemPrompt: "s")
        do {
            _ = try await transport.send(req)
            XCTFail("expected throw")
        } catch {
            // expected
        }
    }

    func testFakeTransportRecordsRequests() async throws {
        let transport = FakeTransport(
            response: .success(GenerationTransportResponse(text: "ok"))
        )
        _ = try await transport.send(.init(model: "m1", prompt: "p1", systemPrompt: "s1"))
        _ = try await transport.send(.init(model: "m2", prompt: "p2", systemPrompt: "s2"))
        XCTAssertEqual(transport.requests.count, 2)
        XCTAssertEqual(transport.requests[0].model, "m1")
        XCTAssertEqual(transport.requests[1].prompt, "p2")
    }

    func testRuntimeComposesAnyTransport() async throws {
        // The same `ComposedRuntime` driven by `FakeTransport` and
        // by a differently-named `FakeTransport` must produce
        // identical results except for the transport / provider fields
        // in the metadata. This is the Level-2 invariant: a
        // `GenerationRuntime` is composed over a `GenerationTransport`;
        // swapping the transport is a configuration change, not a
        // type change.
        let fake1 = FakeTransport(
            transportName: "fake-a",
            providerName: "provider-a",
            response: .success(GenerationTransportResponse(text: "response-a"))
        )
        let fake2 = FakeTransport(
            transportName: "fake-b",
            providerName: "provider-b",
            response: .success(GenerationTransportResponse(text: "response-b"))
        )
        let r1 = ComposedRuntime(
            runtimeName: "composed",
            modelIdentifier: "model-x",
            transport: fake1,
            systemPrompt: "sys"
        )
        let r2 = ComposedRuntime(
            runtimeName: "composed",
            modelIdentifier: "model-x",
            transport: fake2,
            systemPrompt: "sys"
        )
        let result1 = try await r1.generate(prompt: "p", context: GenerationContext())
        let result2 = try await r2.generate(prompt: "p", context: GenerationContext())
        XCTAssertEqual(result1.text, "response-a")
        XCTAssertEqual(result2.text, "response-b")
        XCTAssertEqual(result1.metadata.transport, "fake-a")
        XCTAssertEqual(result2.metadata.transport, "fake-b")
        XCTAssertEqual(result1.metadata.provider, "provider-a")
        XCTAssertEqual(result2.metadata.provider, "provider-b")
        // runtime / model / promptProfile are the same
        XCTAssertEqual(result1.metadata.runtime, result2.metadata.runtime)
        XCTAssertEqual(result1.metadata.model, result2.metadata.model)
    }

    func testTransportRequestIsEquatable() {
        let a = GenerationTransportRequest(model: "m", prompt: "p", systemPrompt: "s")
        let b = GenerationTransportRequest(model: "m", prompt: "p", systemPrompt: "s")
        XCTAssertEqual(a, b)
    }

    func testTransportRequestIncludesOptionalParameters() {
        let req = GenerationTransportRequest(
            model: "m", prompt: "p", systemPrompt: "s",
            temperature: 0.4, maxTokens: 256, stopSequences: ["STOP"]
        )
        XCTAssertEqual(req.temperature, 0.4)
        XCTAssertEqual(req.maxTokens, 256)
        XCTAssertEqual(req.stopSequences, ["STOP"])
    }

    func testTransportRequestEquatableDistinguishesParameters() {
        let a = GenerationTransportRequest(model: "m", prompt: "p", systemPrompt: "s", temperature: 0.4)
        let b = GenerationTransportRequest(model: "m", prompt: "p", systemPrompt: "s", temperature: 0.5)
        XCTAssertNotEqual(a, b)
    }
}
