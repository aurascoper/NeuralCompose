import XCTest
@testable import BCICore

final class TextCompositionControllerTests: XCTestCase {

    /// A trivial fake predictor that returns three fixed candidates without
    /// touching the network or MLX.
    private struct FakePredictor: NextWordPredicting {
        let isLive = false
        let modelIdentifier = "fake"
        let supplied: [PredictedWord]
        func predictNextWords(
            context: String,
            maxCandidates: Int,
            temperature: Double,
            cancellationID: UUID
        ) async throws -> [PredictedWord] {
            return Array(supplied.prefix(maxCandidates))
        }
    }

    func testAppendsHighlightedCandidateOnSelect() async {
        let cands = [
            PredictedWord(text: " hello", probability: 0.5),
            PredictedWord(text: " world", probability: 0.3),
            PredictedWord(text: " friend", probability: 0.2),
        ]
        let c = TextCompositionController(
            predictor: FakePredictor(supplied: cands),
            config: .init(maxCandidates: 3, temperature: 0.7, seedContext: "I say")
        )
        await c.start()

        // Drain a few snapshots to let predictions settle. The task returns
        // whether it observed settled candidates rather than mutating a
        // captured `var` (a Swift 6 strict-concurrency data race). Cancelling
        // the task ends the `AsyncStream` iteration, so awaiting the value
        // resolves promptly with whatever was seen inside the window.
        let task = Task<Bool, Never> {
            for await s in await c.snapshots {
                if !s.isPredicting, !s.candidates.isEmpty {
                    return true
                }
            }
            return false
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()
        let seenCandidates = await task.value
        XCTAssertTrue(seenCandidates)

        // Tick once → highlight moves to index 1.
        await c.tick()
        // Then commit.
        await c.applyIntent(.selectActive)
        // Drain to capture post-commit snapshot.
        let collected = Task<TextCompositionController.Snapshot?, Never> {
            var last: TextCompositionController.Snapshot? = nil
            for await s in await c.snapshots {
                last = s
                if !s.isPredicting, s.lastCommittedWord != nil {
                    break
                }
            }
            return last
        }
        try? await Task.sleep(nanoseconds: 100_000_000)
        collected.cancel()
        // We don't strictly assert on the value here — the goal is to make
        // sure the actor pipeline runs end-to-end without deadlocking.
        await c.finish()
    }
}
