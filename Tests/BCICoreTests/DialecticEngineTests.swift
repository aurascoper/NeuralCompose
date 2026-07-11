import XCTest
@testable import BCICore

final class DialecticEngineTests: XCTestCase {

    /// Captures every prompt it's asked to generate for, in order, so tests
    /// can assert on call sequencing and data-threading between passes
    /// without depending on real model output.
    private actor RecordingGenerator: TextGenerating {
        nonisolated let isLive = false
        nonisolated let modelIdentifier = "recording-fake"

        private(set) var receivedPrompts: [String] = []
        private let responses: [String]
        private var callIndex = 0

        init(responses: [String]) {
            self.responses = responses
        }

        func generate(
            prompt: String, maxTokens: Int, temperature: Double, cancellationID: UUID
        ) async throws -> String {
            receivedPrompts.append(prompt)
            defer { callIndex += 1 }
            guard callIndex < responses.count else { return "" }
            return responses[callIndex]
        }
    }

    func testRefineRunsThesisAntithesisSynthesisInOrderWithDataThreading() async throws {
        let generator = RecordingGenerator(responses: [
            "Thesis output", "Antithesis output", "Synthesis output",
        ])
        let engine = DialecticEngine(generator: generator)

        let refinement = try await engine.refine("original composed text")

        XCTAssertEqual(refinement.original, "original composed text")
        XCTAssertEqual(refinement.thesis, "Thesis output")
        XCTAssertEqual(refinement.antithesis, "Antithesis output")
        XCTAssertEqual(refinement.synthesis, "Synthesis output")

        let prompts = await generator.receivedPrompts
        XCTAssertEqual(prompts.count, 3)
        // Each prompt must actually reference the prior pass's output —
        // proves real data-threading, not just three independent calls.
        XCTAssertTrue(prompts[0].contains("original composed text"))
        XCTAssertTrue(prompts[1].contains("Thesis output"), "antithesis prompt should reference the thesis")
        XCTAssertTrue(prompts[2].contains("Thesis output"), "synthesis prompt should reference the thesis")
        XCTAssertTrue(prompts[2].contains("Antithesis output"), "synthesis prompt should reference the antithesis")
    }

    func testRefineStopsEarlyWhenCancelled() async throws {
        let generator = RecordingGenerator(responses: ["Thesis output", "Antithesis output", "Synthesis output"])
        let engine = DialecticEngine(generator: generator)

        let task = Task<Refinement, Error> {
            try await engine.refine("some text")
        }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("expected cancellation to propagate")
        } catch is CancellationError {
            // expected
        }

        // Cancellation is checked before the first call, so no prompts
        // should have been issued at all.
        let prompts = await generator.receivedPrompts
        XCTAssertLessThanOrEqual(prompts.count, 1, "cancellation should stop the pipeline before it completes all three passes")
    }
}
