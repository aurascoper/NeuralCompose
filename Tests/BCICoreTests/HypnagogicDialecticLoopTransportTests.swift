import XCTest
import Foundation
@testable import BCICore

/// Transport commands spoken back to the voice ("say that again", "slow
/// down") are intercepted in `runTurn` before any generation: the last voiced
/// turn is re-spoken (re-rated for slow-down), a candidate-less turn is logged
/// so the harness's turn count still advances, and the silence counter is left
/// alone. The app-side entries do the same without logging a turn.
final class HypnagogicDialecticLoopTransportTests: XCTestCase {

    // MARK: - Spies

    /// Feeds a fixed script, then suspends (no silence cues) so spoken output
    /// can be counted exactly. `cancel()` releases the suspension.
    private actor ScriptListener: HypnagogicListening {
        nonisolated let isLive = false
        private var queue: [String]
        init(_ script: [String]) { queue = script }
        func requestAuthorization() async -> Bool { true }
        func listen(timeout: TimeInterval) async throws -> String? {
            if !queue.isEmpty { return queue.removeFirst() }
            try await Task.sleep(nanoseconds: 10_000_000_000)
            return nil
        }
        func cancel() async {}
    }

    private actor TwoRoleGenerator: TextGenerating {
        nonisolated let isLive = false
        nonisolated let modelIdentifier = "spy-two-role"
        private let stabilizer: String
        private let dreamer: String
        private(set) var prompts: [String] = []
        init(stabilizer: String, dreamer: String) {
            self.stabilizer = stabilizer; self.dreamer = dreamer
        }
        func generate(prompt: String, maxTokens: Int, temperature: Double,
                      cancellationID: UUID) async throws -> String {
            prompts.append(prompt)
            return temperature >= 0.9 ? dreamer : stabilizer
        }
    }

    private struct MapEmbedder: SentenceEmbedder {
        let modelID = "map-v1"
        let dimension: Int
        let version = "1"
        let table: [String: [Float]]
        func encode(_ texts: [String]) async throws -> [Embedding] {
            texts.map { t in
                let v = table[t] ?? [Float](repeating: 0, count: dimension)
                let norm = sqrtf(v.reduce(0) { $0 + $1 * $1 })
                let unit = norm > 0 ? v.map { $0 / norm } : v
                return Embedding(values: unit, modelID: modelID,
                                 dimension: dimension, version: version, seed: 0)
            }
        }
    }

    /// Records every chunk with the prosody it was requested at.
    private actor ProsodySpySpeaker: SpeechSynthesizing {
        nonisolated let isLive = false
        nonisolated let voiceIdentifier = "spy-voice"
        private(set) var spoken: [(text: String, prosody: SpeechProsody?)] = []
        func speak(_ text: String) async throws { spoken.append((text, nil)) }
        func speak(_ text: String, prosody: SpeechProsody) async throws { spoken.append((text, prosody)) }
        func speak(_ text: String, prosody: SpeechProsody,
                   onWord: (@Sendable (SpokenWord) -> Void)?) async throws {
            spoken.append((text, prosody))
            onWord?(SpokenWord(text: text, characterOffset: 0))
        }
        func stopSpeaking() async {}
        var texts: [String] { spoken.map(\.text) }
    }

    private actor CapturingTurnLogger: DialecticalTurnLogging {
        private(set) var events: [DialecticalTurnEvent] = []
        func log(_ event: DialecticalTurnEvent) async { events.append(event) }
    }

    // MARK: - Fixture

    private let embedder = MapEmbedder(dimension: 2, table: [
        "the sea": [1, 0], "calm sea": [1, 0], "moon river": [0, 1],
    ])

    private func makeLoop(script: [String])
        -> (HypnagogicDialecticLoop, TwoRoleGenerator, ProsodySpySpeaker, CapturingTurnLogger) {
        let generator = TwoRoleGenerator(stabilizer: "calm sea", dreamer: "moon river")
        let speaker = ProsodySpySpeaker()
        let logger = CapturingTurnLogger()
        let loop = HypnagogicDialecticLoop(
            listener: ScriptListener(script), generator: generator, speaker: speaker,
            embedder: embedder, random: { 0.5 }, turnLogger: logger,
            config: HypnagogicDialecticLoop.Config(listenTimeout: 0.01, interTurnDelayNanos: 1_000)
        )
        return (loop, generator, speaker, logger)
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

    // MARK: - Classification

    func testClassifyTransportCommandRecognizesTheLoggedPhrases() {
        typealias T = HypnagogicDialecticLoop
        XCTAssertEqual(T.classifyTransportCommand("Say that again"), .repeatLast)
        XCTAssertEqual(T.classifyTransportCommand("repeat that."), .repeatLast)
        XCTAssertEqual(T.classifyTransportCommand("Can you repeat that?"), .repeatLast)
        XCTAssertEqual(T.classifyTransportCommand("what did you say"), .repeatLast)
        XCTAssertEqual(T.classifyTransportCommand("please say that again"), .repeatLast)
        XCTAssertEqual(T.classifyTransportCommand("slow down"), .slowDown)
        XCTAssertEqual(T.classifyTransportCommand("Slow down, please"), .slowDown)
        XCTAssertEqual(T.classifyTransportCommand("say that slower"), .slowDown)
        XCTAssertEqual(T.classifyTransportCommand("can you repeat that slower"), .slowDown)
        XCTAssertEqual(T.classifyTransportCommand("too fast"), .slowDown)
    }

    func testClassifyTransportCommandLeavesPromptsAlone() {
        typealias T = HypnagogicDialecticLoop
        XCTAssertNil(T.classifyTransportCommand("say that the sea is calm"))
        XCTAssertNil(T.classifyTransportCommand("what did you say about the window"))
        XCTAssertNil(T.classifyTransportCommand("the tide is slow down there"))
        XCTAssertNil(T.classifyTransportCommand(""))
        XCTAssertNil(T.classifyTransportCommand("turn off"), "memory reset is a different command")
    }

    // MARK: - In-turn intercept

    func testSayThatAgainReSpeaksTheLastReplyWithoutGenerating() async {
        let (loop, generator, speaker, logger) = makeLoop(script: ["the sea", "say that again"])
        await loop.start()
        let ok = await poll { await speaker.texts.count >= 2 }
        await loop.stop()
        XCTAssertTrue(ok, "the reply must be voiced twice: once for the turn, once for the repeat")

        let texts = await speaker.texts
        XCTAssertEqual(texts, ["calm sea", "calm sea"])
        let prompts = await generator.prompts.count
        XCTAssertEqual(prompts, 2, "the repeat must not reach the generators (two roles, one real turn)")

        let events = await logger.events
        XCTAssertEqual(events.count, 2, "the repeat is logged as its own turn so the run's count advances")
        XCTAssertEqual(events.last?.heard, "say that again")
        XCTAssertEqual(events.last?.outcome, "silent",
                       "a transport turn logs a candidate-less silent outcome")
        XCTAssertEqual(events.last?.candidates.count, 0)
        let turnIndex = await loop.turnIndex
        XCTAssertEqual(turnIndex, 2)
        let lastText = await loop.lastVoicedText
        XCTAssertEqual(lastText, "calm sea", "a replay does not replace the remembered turn")
    }

    func testSlowDownLowersTheRateAndReSpeaks() async {
        let (loop, generator, speaker, _) = makeLoop(script: ["the sea", "slow down"])
        await loop.start()
        let ok = await poll { await speaker.texts.count >= 2 }
        await loop.stop()
        XCTAssertTrue(ok)

        let spoken = await speaker.spoken
        XCTAssertEqual(spoken.map(\.text), ["calm sea", "calm sea"])
        guard let first = spoken[0].prosody?.rate, let second = spoken[1].prosody?.rate else {
            return XCTFail("both utterances must carry a requested rate")
        }
        XCTAssertEqual(second, first - HypnagogicDialecticLoop.slowDownStep, accuracy: 1e-4)
        let offset = await loop.currentSpeechRateOffset
        XCTAssertEqual(offset, -HypnagogicDialecticLoop.slowDownStep, accuracy: 1e-6)
        let prompts = await generator.prompts.count
        XCTAssertEqual(prompts, 2, "slow down never generates")
    }

    func testStandingSlowDownShapesTheNextVoicedTurnToo() async {
        // Compare the second real turn ("the sea") after a "slow down" against
        // the second real turn of an un-slowed loop with the identical history
        // (Turn 1 populates DialecticalMemory's history/reply centroids, which
        // shifts the unadjusted competition blend slightly between Turn 1 and
        // the second real turn).
        let (baselineLoop, _, baselineSpeaker, _) = makeLoop(script: ["the sea", "the sea"])
        await baselineLoop.start()
        let baseOK = await poll { await baselineSpeaker.texts.count >= 2 }
        await baselineLoop.stop()
        XCTAssertTrue(baseOK)
        let baselineSpoken = await baselineSpeaker.spoken

        let (loop, _, speaker, _) = makeLoop(script: ["the sea", "slow down", "the sea"])
        await loop.start()
        let ok = await poll { await speaker.texts.count >= 3 }
        await loop.stop()
        XCTAssertTrue(ok)
        let spoken = await speaker.spoken
        guard baselineSpoken.count >= 2, spoken.count >= 3,
              let baselineSecond = baselineSpoken[1].prosody?.rate,
              let third = spoken[2].prosody?.rate else {
            return XCTFail("expected rated utterances, got \(spoken.count)")
        }
        XCTAssertEqual(third, baselineSecond - HypnagogicDialecticLoop.slowDownStep, accuracy: 1e-5,
                       "a later real turn is voiced at the lowered rate relative to its unadjusted competition blend")
    }

    func testReplayPreservesNodeIDEmbeddingSilenceCounterAndMemory() async {
        // Set maxConsecutiveSilence = 2 so that if transport turns incremented
        // consecutiveSilence, two repeats in a row would trigger a silence cue.
        let generator = TwoRoleGenerator(stabilizer: "calm sea", dreamer: "moon river")
        let speaker = ProsodySpySpeaker()
        let logger = CapturingTurnLogger()
        let loop = HypnagogicDialecticLoop(
            listener: ScriptListener(["the sea", "say that again", "repeat that", "the sea"]),
            generator: generator,
            speaker: speaker,
            embedder: embedder,
            random: { 0.5 },
            turnLogger: logger,
            config: HypnagogicDialecticLoop.Config(
                listenTimeout: 0.01,
                interTurnDelayNanos: 1_000,
                maxConsecutiveSilence: 2,
                silenceCues: ["SILENCE_CUE_SHOULD_NOT_FIRE"]
            )
        )
        let nodeStream = loop.spokenNodeStream()
        let collectedNodes = Task { () -> [SpokenNodeEvent] in
            var result: [SpokenNodeEvent] = []
            for await event in nodeStream {
                result.append(event)
                // Turn 0 emits place (nil word) + 1 word event; two replays emit
                // 1 word event each; Turn 3 emits place + 1 word event = 6 total.
                if result.count >= 6 { break }
            }
            return result
        }

        await loop.start()
        let ok = await poll { await speaker.texts.count >= 4 }
        await loop.stop()
        XCTAssertTrue(ok)

        let spokenTexts = await speaker.texts
        XCTAssertEqual(spokenTexts, ["calm sea", "calm sea", "calm sea", "calm sea"],
                       "no silence cue should fire across consecutive transport turns")

        let prompts = await generator.prompts
        XCTAssertEqual(prompts.count, 4, "only the two real 'the sea' turns call the two role generators")
        // Verify that the second real turn's history preamble has exactly one
        // exchange from Turn 0 and no duplicate or transport-turn entries.
        let secondTurnPrompt = prompts[2]
        let occurrences = secondTurnPrompt.components(separatedBy: "You replied: calm sea").count - 1
        XCTAssertEqual(occurrences, 1, "replay must not append a duplicate reply to conversation history")
        XCTAssertFalse(secondTurnPrompt.contains("say that again"))
        XCTAssertFalse(secondTurnPrompt.contains("repeat that"))

        let nodeEvents = await collectedNodes.value
        let replayWordEvents = nodeEvents.filter { $0.word != nil }
        XCTAssertGreaterThanOrEqual(replayWordEvents.count, 3)
        // First three word events (Turn 0 + two replays) must all reference node "0" and the identical embedding.
        XCTAssertEqual(replayWordEvents[0].nodeID, "0")
        XCTAssertEqual(replayWordEvents[1].nodeID, "0")
        XCTAssertEqual(replayWordEvents[2].nodeID, "0")
        XCTAssertEqual(replayWordEvents[1].embedding, replayWordEvents[0].embedding)
        XCTAssertEqual(replayWordEvents[2].embedding, replayWordEvents[0].embedding)
    }

    func testTransportCommandBeforeAnyReplyLogsATurnAndSpeaksNothing() async {
        let (loop, generator, speaker, logger) = makeLoop(script: ["say that again"])
        await loop.start()
        let ok = await poll { await logger.events.count >= 1 }
        await loop.stop()
        XCTAssertTrue(ok)
        let texts = await speaker.texts
        XCTAssertTrue(texts.isEmpty, "nothing has been voiced yet, so nothing is repeated")
        let prompts = await generator.prompts.count
        XCTAssertEqual(prompts, 0)
        let turnIndex = await loop.turnIndex
        XCTAssertEqual(turnIndex, 1)
    }

    // MARK: - App-side entries

    func testAppSideRepeatSpeaksWithoutLoggingATurn() async throws {
        let (loop, _, speaker, logger) = makeLoop(script: ["the sea"])
        await loop.start()
        let ok = await poll { await speaker.texts.count >= 1 }
        XCTAssertTrue(ok)
        try await loop.repeatLastUtterance()
        let texts = await speaker.texts
        XCTAssertEqual(texts, ["calm sea", "calm sea"])
        let events = await logger.events.count
        XCTAssertEqual(events, 1, "an app-triggered repeat heard nothing, so no turn is logged")
        await loop.stop()
    }

    func testSlowDownOffsetIsFlooredAndIsANoOpSpeechBeforeAnyTurn() async throws {
        let (loop, _, speaker, logger) = makeLoop(script: [])
        for _ in 0..<5 { try await loop.slowDownSpeech() }
        let offset = await loop.currentSpeechRateOffset
        XCTAssertEqual(offset, HypnagogicDialecticLoop.maxSlowDownOffset, accuracy: 1e-6)
        let texts = await speaker.texts
        XCTAssertTrue(texts.isEmpty)
        let events = await logger.events.count
        XCTAssertEqual(events, 0)
    }
}
