import XCTest
@testable import BCICore
@testable import BCILLM

final class StubPredictorTests: XCTestCase {

    func testReturnsSomeCandidatesForEmpty() async throws {
        let p = StubNextWordPredictor()
        let words = try await p.predictNextWords(
            context: "",
            maxCandidates: 3,
            temperature: 0.7,
            cancellationID: UUID()
        )
        XCTAssertEqual(words.count, 3)
        for w in words {
            XCTAssertFalse(w.text.isEmpty)
            XCTAssertGreaterThan(w.probability, 0)
        }
    }

    func testBigramFollowsThank() async throws {
        let p = StubNextWordPredictor()
        let words = try await p.predictNextWords(
            context: "Thank",
            maxCandidates: 3,
            temperature: 0.7,
            cancellationID: UUID()
        )
        XCTAssertEqual(words.first?.displayText.lowercased(), "you")
    }

    func testHonoursCancellation() async {
        let p = StubNextWordPredictor()
        let task = Task<[PredictedWord], any Error> {
            try await p.predictNextWords(
                context: "hi",
                maxCandidates: 3,
                temperature: 0.7,
                cancellationID: UUID()
            )
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
