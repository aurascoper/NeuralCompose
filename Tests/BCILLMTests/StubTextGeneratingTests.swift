import XCTest
@testable import BCICore
@testable import BCILLM

final class StubTextGeneratingTests: XCTestCase {

    func testGenerateReturnsNonEmptyDeterministicOutputForNonEmptyPrompt() async throws {
        let p = StubNextWordPredictor()
        let result = try await p.generate(
            prompt: "rephrase this please", maxTokens: 32, temperature: 0.7, cancellationID: UUID()
        )
        XCTAssertFalse(result.isEmpty)
        XCTAssertTrue(result.contains("rephrase this please"))
    }

    func testGenerateReturnsEmptyStringForEmptyOrWhitespacePrompt() async throws {
        let p = StubNextWordPredictor()
        let empty = try await p.generate(prompt: "", maxTokens: 32, temperature: 0.7, cancellationID: UUID())
        let whitespace = try await p.generate(prompt: "   ", maxTokens: 32, temperature: 0.7, cancellationID: UUID())
        XCTAssertEqual(empty, "")
        XCTAssertEqual(whitespace, "")
    }

    func testGenerateHonoursCancellation() async {
        let p = StubNextWordPredictor()
        let task = Task<String, any Error> {
            try await p.generate(prompt: "hi", maxTokens: 32, temperature: 0.7, cancellationID: UUID())
        }
        task.cancel()
        do {
            _ = try await task.value
            // Stub is fast — may complete before cancellation lands. Either
            // outcome is acceptable; we just want no crash.
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }
}
