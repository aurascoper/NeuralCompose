import XCTest
@testable import BCICore

final class SpokenGenerationLoopTests: XCTestCase {

    /// Records the prompts it's asked to generate for; returns a canned string.
    private actor SpyGenerator: TextGenerating {
        nonisolated let isLive = false
        nonisolated let modelIdentifier = "spy-gen"
        private(set) var prompts: [String] = []
        private let response: String
        init(response: String) { self.response = response }
        func generate(prompt: String, maxTokens: Int, temperature: Double,
                      cancellationID: UUID) async throws -> String {
            prompts.append(prompt)
            return response
        }
    }

    /// Records what it was asked to speak and how often it was interrupted.
    private actor SpySpeaker: SpeechSynthesizing {
        nonisolated let isLive = false
        nonisolated let voiceIdentifier = "spy-voice"
        private(set) var spoken: [String] = []
        private(set) var stopCount = 0
        func speak(_ text: String) async throws { spoken.append(text) }
        func stopSpeaking() async { stopCount += 1 }
    }

    private func fastConfig(useDialectic: Bool = false) -> SpokenGenerationLoop.Config {
        // ~1µs inter-utterance delay keeps the loop hot so tests observe cycles
        // quickly; production defaults to seconds.
        SpokenGenerationLoop.Config(seedPrompt: "seed", maxTokens: 8,
                                    interUtteranceDelayNanos: 1_000, useDialectic: useDialectic)
    }

    /// Polls `predicate` until true or `timeout` elapses.
    private func poll(timeout: TimeInterval = 2.0,
                      _ predicate: @Sendable () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await predicate() { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return await predicate()
    }

    func testLoopGeneratesThenSpeaks() async {
        let generator = SpyGenerator(response: "hello world")
        let speaker = SpySpeaker()
        let loop = SpokenGenerationLoop(generator: generator, speaker: speaker,
                                        adaptationProvider: { .raw }, config: fastConfig())
        await loop.start()
        let progressed = await poll {
            // Evaluate both awaited actor reads into locals: `await` can't appear
            // inside the short-circuit autoclosure on the right of `&&`.
            let generated = await generator.prompts.count
            let spoke = await speaker.spoken.count
            return generated >= 1 && spoke >= 1
        }
        XCTAssertTrue(progressed, "loop should generate then speak")
        let first = await speaker.spoken.first
        XCTAssertEqual(first, "hello world", "spoken text must be the generator's output")
        await loop.stop()
    }

    func testStopCancelsAndHalts() async {
        let generator = SpyGenerator(response: "line")
        let speaker = SpySpeaker()
        let loop = SpokenGenerationLoop(generator: generator, speaker: speaker,
                                        adaptationProvider: { .raw }, config: fastConfig())
        await loop.start()
        _ = await poll { await speaker.spoken.count >= 1 }

        await loop.stop()
        let running = await loop.isRunning
        XCTAssertFalse(running, "isRunning must be false after stop()")
        let stops = await speaker.stopCount
        XCTAssertGreaterThanOrEqual(stops, 1, "stop() must interrupt the speaker")

        // Let any in-flight iteration finish and the cancelled task terminate,
        // then confirm the spoken count stops growing.
        try? await Task.sleep(nanoseconds: 50_000_000)
        let snapshot = await speaker.spoken.count
        try? await Task.sleep(nanoseconds: 50_000_000)
        let after = await speaker.spoken.count
        XCTAssertEqual(after, snapshot, "loop must not keep speaking after stop()")
    }

    func testPromptCarriesStyleInstructionFromAdaptation() async {
        let generator = SpyGenerator(response: "x")
        let speaker = SpySpeaker()
        let adaptation = GenerationAdaptation(
            maxCandidates: 2, temperature: 0.3,
            styleInstruction: "Prefer short, common, high-confidence words.")
        let loop = SpokenGenerationLoop(generator: generator, speaker: speaker,
                                        adaptationProvider: { adaptation }, config: fastConfig())
        await loop.start()
        _ = await poll { await generator.prompts.count >= 1 }
        await loop.stop()
        let firstPrompt = await generator.prompts.first ?? ""
        XCTAssertTrue(firstPrompt.contains("Prefer short, common, high-confidence words."),
                      "prompt must include the adaptation's styleInstruction")
    }
}
