import XCTest
@testable import BCICore

final class HypnagogicDialogueLoopTests: XCTestCase {

    /// Yields scripted transcripts (or nil = silence) per listen turn; records
    /// how often it was asked to listen and to cancel.
    private actor SpyListener: HypnagogicListening {
        nonisolated let isLive = false
        private var queue: [String?]
        private(set) var listenCount = 0
        private(set) var cancelCount = 0
        init(script: [String?]) { self.queue = script }
        func requestAuthorization() async -> Bool { true }
        func listen(timeout: TimeInterval) async throws -> String? {
            listenCount += 1
            if queue.isEmpty {
                try? await Task.sleep(nanoseconds: 5_000_000) // idle as "silence"
                return nil
            }
            return queue.removeFirst()
        }
        func cancel() async { cancelCount += 1 }
    }

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

    private actor SpySpeaker: SpeechSynthesizing {
        nonisolated let isLive = false
        nonisolated let voiceIdentifier = "spy-voice"
        private(set) var spoken: [String] = []
        private(set) var prosodies: [SpeechProsody] = []
        private(set) var stopCount = 0
        func speak(_ text: String) async throws { spoken.append(text); prosodies.append(SpeechProsody()) }
        func speak(_ text: String, prosody: SpeechProsody) async throws {
            spoken.append(text); prosodies.append(prosody)
        }
        func stopSpeaking() async { stopCount += 1 }
    }

    private func fastConfig() -> HypnagogicDialogueLoop.Config {
        HypnagogicDialogueLoop.Config(listenTimeout: 0.01, interTurnDelayNanos: 1_000)
    }

    private func poll(timeout: TimeInterval = 2.0,
                      _ predicate: @Sendable () async -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await predicate() { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return await predicate()
    }

    func testHeardTranscriptDrivesGenerationThenHypnagogicSpeech() async {
        let listener = SpyListener(script: ["I see a door"])
        let generator = SpyGenerator(response: "You drift. The door softens.")
        let speaker = SpySpeaker()
        let loop = HypnagogicDialogueLoop(listener: listener, generator: generator,
                                          speaker: speaker, config: fastConfig())
        await loop.start()
        let ok = await poll {
            let gen = await generator.prompts.first
            let spoke = await speaker.spoken.count
            return gen == "I see a door" && spoke >= 1
        }
        XCTAssertTrue(ok, "a heard transcript must go to the generator, then be spoken")
        // Speech is chunked on punctuation and uses hypnagogic prosody.
        let spoken = await speaker.spoken
        XCTAssertTrue(spoken.contains("You drift."), "reply should be chunked into micro-phrases")
        let prosody = await speaker.prosodies.first
        XCTAssertEqual(prosody?.rate, SpeechProsody.hypnagogic.rate, "must speak with hypnagogic prosody")
        await loop.stop()
    }

    func testSilentTurnSpeaksCueWithoutCallingModel() async {
        let listener = SpyListener(script: [nil])
        let generator = SpyGenerator(response: "should-not-be-used")
        let speaker = SpySpeaker()
        let loop = HypnagogicDialogueLoop(listener: listener, generator: generator,
                                          speaker: speaker, config: fastConfig())
        await loop.start()
        let spoke = await poll { await speaker.spoken.count >= 1 }
        XCTAssertTrue(spoke, "a silent turn must still speak an induction cue")
        let calledModel = await generator.prompts.count
        XCTAssertEqual(calledModel, 0, "a silent turn must NOT call the (possibly cloud) model")
        await loop.stop()
    }

    func testStopHaltsCancelsListenerAndInterruptsSpeech() async {
        let listener = SpyListener(script: ["one"])
        let generator = SpyGenerator(response: "soft reply")
        let speaker = SpySpeaker()
        let loop = HypnagogicDialogueLoop(listener: listener, generator: generator,
                                          speaker: speaker, config: fastConfig())
        await loop.start()
        _ = await poll { await speaker.spoken.count >= 1 }
        await loop.stop()

        let running = await loop.isRunning
        XCTAssertFalse(running, "isRunning must be false after stop()")
        let cancels = await listener.cancelCount
        XCTAssertGreaterThanOrEqual(cancels, 1, "stop() must cancel the listener")
        let stops = await speaker.stopCount
        XCTAssertGreaterThanOrEqual(stops, 1, "stop() must interrupt the speaker")

        try? await Task.sleep(nanoseconds: 40_000_000)
        let snapshot = await speaker.spoken.count
        try? await Task.sleep(nanoseconds: 40_000_000)
        let after = await speaker.spoken.count
        XCTAssertEqual(after, snapshot, "loop must not keep speaking after stop()")
    }

    func testChunkSplitsOnPunctuation() {
        XCTAssertEqual(HypnagogicDialogueLoop.chunk("You drift. The door softens."),
                       ["You drift.", "The door softens."])
        XCTAssertEqual(HypnagogicDialogueLoop.chunk("floating, sinking, warm"),
                       ["floating,", "sinking,", "warm"])
        XCTAssertEqual(HypnagogicDialogueLoop.chunk("   "), [])
        XCTAssertEqual(HypnagogicDialogueLoop.chunk("no punctuation"), ["no punctuation"])
    }
}
