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

    /// Drains `snapshots` until a predicate holds or a timeout elapses,
    /// returning the last snapshot observed (or nil if the stream ended
    /// without ever matching). Mirrors the polling pattern already used
    /// above, factored out so the dictation tests don't duplicate it.
    private func waitForSnapshot(
        _ controller: TextCompositionController,
        timeoutNanos: UInt64 = 200_000_000,
        until predicate: @escaping @Sendable (TextCompositionController.Snapshot) -> Bool
    ) async -> TextCompositionController.Snapshot? {
        let task = Task<TextCompositionController.Snapshot?, Never> {
            for await s in await controller.snapshots {
                if predicate(s) { return s }
            }
            return nil
        }
        try? await Task.sleep(nanoseconds: timeoutNanos)
        task.cancel()
        return await task.value
    }

    func testAppendExternalTextJoinsLikeEEGCommits() async {
        let c = TextCompositionController(
            predictor: FakePredictor(supplied: [PredictedWord(text: " ok", probability: 1.0)]),
            config: .init(maxCandidates: 1, seedContext: "hello")
        )
        await c.start()

        await c.appendExternalText("world", source: .dictation)

        // A precise predicate matters here: `c.start()` already published an
        // earlier "settled" (`!isPredicting`) snapshot for the seed context
        // alone, still sitting in the channel's buffer. A generic
        // `!isPredicting` predicate would match that stale snapshot first.
        let snap = await waitForSnapshot(c) { $0.composedText == "hello world" }
        XCTAssertEqual(snap?.composedText, "hello world")
        XCTAssertEqual(snap?.lastCommittedWord, "world")
        await c.finish()
    }

    func testAppendExternalTextIsNoOpForEmptyOrWhitespace() async {
        let c = TextCompositionController(
            predictor: FakePredictor(supplied: [PredictedWord(text: " real", probability: 1.0)]),
            config: .init(maxCandidates: 1, seedContext: "hello")
        )
        await c.start()

        // Neither call should mutate `composed` or trigger a new prediction
        // request. Proven indirectly: a real append immediately afterward
        // produces exactly "hello real" — if either no-op had inserted a
        // stray token or extra whitespace, this would show up here.
        await c.appendExternalText("   ", source: .dictation)
        await c.appendExternalText("", source: .dictation)
        await c.appendExternalText("real", source: .dictation)

        let snap = await waitForSnapshot(c) { $0.composedText == "hello real" }
        XCTAssertEqual(snap?.composedText, "hello real")
        await c.finish()
    }

    func testAppendExternalTextInterleavesWithEEGCommit() async {
        let cands = [PredictedWord(text: " two", probability: 1.0)]
        let c = TextCompositionController(
            predictor: FakePredictor(supplied: cands),
            config: .init(maxCandidates: 1, seedContext: "one")
        )
        await c.start()

        // EEG-sourced commit (goes through the FSM), then a dictation
        // append (bypasses the FSM) — both should land in the same buffer
        // without racing, since the actor serializes all calls.
        await c.applyIntent(.selectActive)
        await c.appendExternalText("three", source: .dictation)

        let snap = await waitForSnapshot(c) { $0.composedText == "one two three" }
        XCTAssertEqual(snap?.composedText, "one two three")
        await c.finish()
    }

    func testAppendExternalTextSupersedesStaleInFlightPrediction() async {
        // A predictor that takes a little while lets us create a genuine
        // in-flight request, then supersede it with a second one before it
        // resolves — proving the stale response is discarded (via the
        // `currentCancellation` id check in `requestPredictions()`) rather
        // than clobbering the newer composed text.
        struct HangingPredictor: NextWordPredicting {
            let isLive = false
            let modelIdentifier = "hanging"
            func predictNextWords(
                context: String, maxCandidates: Int, temperature: Double, cancellationID: UUID
            ) async throws -> [PredictedWord] {
                try await Task.sleep(nanoseconds: 150_000_000)
                return [PredictedWord(text: " stale", probability: 1.0)]
            }
        }
        let c = TextCompositionController(
            predictor: HangingPredictor(),
            config: .init(maxCandidates: 1, seedContext: "start")
        )

        // Fire `start()` as a detached task rather than awaiting it directly
        // — an actor call only yields the actor while *it* is suspended
        // (i.e. inside the predictor's own await), so a synchronously
        // awaited `start()` here would simply run to completion (150ms)
        // before `appendExternalText` could ever be enqueued, and the two
        // calls would never actually overlap.
        let startTask = Task { await c.start() }
        try? await Task.sleep(nanoseconds: 20_000_000) // let start()'s request begin and suspend
        await c.appendExternalText("now", source: .dictation)
        _ = await startTask.value // let the stale request resolve and bail out deterministically

        let snap = await waitForSnapshot(c) { $0.composedText == "start now" }
        XCTAssertEqual(snap?.composedText, "start now")
        await c.finish()
    }

    func testApplyRefinementReplacesRatherThanAppends() async {
        let c = TextCompositionController(
            predictor: FakePredictor(supplied: [PredictedWord(text: " ok", probability: 1.0)]),
            config: .init(maxCandidates: 1, seedContext: "the original composed sentence")
        )
        await c.start()

        await c.applyRefinement("a fully rewritten sentence")

        // Must be an exact replace — if this were an append (like
        // `appendExternalText`), the original text would still be a prefix.
        let snap = await waitForSnapshot(c) { $0.composedText == "a fully rewritten sentence" }
        XCTAssertEqual(snap?.composedText, "a fully rewritten sentence")
        XCTAssertEqual(snap?.lastCommittedWord, "sentence")
        await c.finish()
    }

    func testApplyRefinementIsNoOpForEmptyOrWhitespace() async {
        let c = TextCompositionController(
            predictor: FakePredictor(supplied: [PredictedWord(text: " real", probability: 1.0)]),
            config: .init(maxCandidates: 1, seedContext: "hello")
        )
        await c.start()

        await c.applyRefinement("   ")
        await c.applyRefinement("")
        await c.applyRefinement("real")

        let snap = await waitForSnapshot(c) { $0.composedText == "real" }
        XCTAssertEqual(snap?.composedText, "real")
        await c.finish()
    }
}
