import XCTest
@testable import BCICore

final class TextCompositionControllerAdaptationTests: XCTestCase {

    /// Records the parameters of the most recent `predictNextWords` call so
    /// tests can assert on exactly what the controller sent, without
    /// touching the network or MLX. An `actor` (not a plain struct, unlike
    /// `TextCompositionControllerTests.FakePredictor`) because it needs
    /// mutable state that's safe to read back across the actor boundary.
    private actor SpyPredictor: NextWordPredicting {
        let isLive = false
        let modelIdentifier = "spy"
        private let supplied: [PredictedWord]
        private(set) var lastContext: String?
        private(set) var lastMaxCandidates: Int?
        private(set) var lastTemperature: Double?

        init(supplied: [PredictedWord]) {
            self.supplied = supplied
        }

        func predictNextWords(
            context: String,
            maxCandidates: Int,
            temperature: Double,
            cancellationID: UUID
        ) async throws -> [PredictedWord] {
            lastContext = context
            lastMaxCandidates = maxCandidates
            lastTemperature = temperature
            return Array(supplied.prefix(maxCandidates))
        }
    }

    private func waitForSnapshot(
        _ controller: TextCompositionController,
        timeoutNanos: UInt64 = 200_000_000,
        until predicate: @escaping @Sendable (TextCompositionController.Snapshot) -> Bool
    ) async -> TextCompositionController.Snapshot? {
        let task = Task<TextCompositionController.Snapshot?, Never> {
            for await s in controller.snapshots {
                if predicate(s) { return s }
            }
            return nil
        }
        try? await Task.sleep(nanoseconds: timeoutNanos)
        task.cancel()
        return await task.value
    }

    func testDefaultAdaptationMatchesConfigDefaults() async {
        let spy = SpyPredictor(supplied: [PredictedWord(text: " ok", probability: 1.0)])
        let c = TextCompositionController(
            predictor: spy,
            config: .init(maxCandidates: 3, temperature: 0.7, seedContext: "hello")
        )
        await c.start()
        _ = await waitForSnapshot(c) { !$0.isPredicting }

        let lastMax = await spy.lastMaxCandidates
        let lastTemp = await spy.lastTemperature
        let lastContext = await spy.lastContext
        XCTAssertEqual(lastMax, 3)
        XCTAssertEqual(lastTemp, 0.7)
        // No style instruction by default — prompt equals the seed context exactly.
        XCTAssertEqual(lastContext, "hello")

        await c.finish()
    }

    func testUpdateGenerationAdaptationChangesPredictorParamsAndPromptPrefixButNotDisplayText() async {
        let spy = SpyPredictor(supplied: [PredictedWord(text: " ok", probability: 1.0)])
        let c = TextCompositionController(
            predictor: spy,
            config: .init(maxCandidates: 3, temperature: 0.7, seedContext: "hello")
        )
        await c.start()
        _ = await waitForSnapshot(c) { !$0.isPredicting }

        let adapted = GenerationAdaptation(maxCandidates: 2, temperature: 0.3, styleInstruction: "Prefer short words.")
        await c.updateGenerationAdaptation(adapted)

        await c.appendExternalText("there", source: .dictation)
        let snap = await waitForSnapshot(c) { $0.composedText == "hello there" }

        let lastMax = await spy.lastMaxCandidates
        let lastTemp = await spy.lastTemperature
        let lastContext = await spy.lastContext
        XCTAssertEqual(lastMax, 2)
        XCTAssertEqual(lastTemp, 0.3)
        XCTAssertEqual(lastContext, "Prefer short words.\nhello there")

        // The style instruction must never leak into what's displayed/composed.
        XCTAssertEqual(snap?.composedText, "hello there")

        await c.finish()
    }

    func testEmptyStyleInstructionLeavesPromptUnprefixed() async {
        let spy = SpyPredictor(supplied: [PredictedWord(text: " ok", probability: 1.0)])
        let c = TextCompositionController(
            predictor: spy,
            config: .init(maxCandidates: 3, temperature: 0.7, seedContext: "hello")
        )
        await c.start()
        _ = await waitForSnapshot(c) { !$0.isPredicting }

        // Non-default candidates/temperature, but an explicitly empty instruction.
        await c.updateGenerationAdaptation(GenerationAdaptation(maxCandidates: 2, temperature: 0.3))
        await c.appendExternalText("there", source: .dictation)
        _ = await waitForSnapshot(c) { $0.composedText == "hello there" }

        let lastContext = await spy.lastContext
        XCTAssertEqual(lastContext, "hello there")

        await c.finish()
    }
}
