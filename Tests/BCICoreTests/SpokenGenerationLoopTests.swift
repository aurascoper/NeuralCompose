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

    /// Throws on every generate — models the *broken* case (stub / MLX-not-loaded)
    /// the loop otherwise swallows silently.
    private struct BoomGenerator: TextGenerating {
        let isLive = false
        let modelIdentifier = "boom-gen"
        func generate(prompt: String, maxTokens: Int, temperature: Double,
                      cancellationID: UUID) async throws -> String {
            throw BoomError.boom
        }
    }
    private enum BoomError: Error { case boom }

    /// Throws on every utterance — models a speech failure *after* generation
    /// already succeeded, so `spoke` must stay false while `generated` is captured.
    private struct BoomSpeaker: SpeechSynthesizing {
        nonisolated let isLive = false
        nonisolated let voiceIdentifier = "boom-voice"
        func speak(_ text: String) async throws { throw BoomError.boom }
        func stopSpeaking() async {}
    }

    /// Accumulates every per-cycle trace event the loop emits.
    private actor SpyTraceLogger: SpokenGenerationTraceLogging {
        private(set) var events: [SpokenGenerationTraceEvent] = []
        func log(_ event: SpokenGenerationTraceEvent) async { events.append(event) }
    }

    /// Accumulates every requested prosody vector the loop emits.
    private actor SpyProsodyTraceLogger: ProsodyTraceLogging {
        private(set) var events: [ProsodyTraceEvent] = []
        func log(_ event: ProsodyTraceEvent) async { events.append(event) }
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

    // MARK: - Per-cycle trace hook

    func testTracerRecordsInputAndOutputPerCycle() async {
        let generator = SpyGenerator(response: "a calm sentence")
        let speaker = SpySpeaker()
        let tracer = SpyTraceLogger()
        let adaptation = GenerationAdaptation(
            maxCandidates: 3, temperature: 0.42, styleInstruction: "Prefer common words.")
        let loop = SpokenGenerationLoop(
            generator: generator, speaker: speaker,
            adaptationProvider: { adaptation }, config: fastConfig(), tracer: tracer)
        await loop.start()
        _ = await poll { await tracer.events.count >= 2 }
        await loop.stop()

        let events = await tracer.events
        XCTAssertGreaterThanOrEqual(events.count, 2, "a trace event must be emitted every cycle")
        let first = events[0]
        XCTAssertEqual(first.index, 0, "cycle counter starts at 0")
        XCTAssertEqual(events[1].index, 1, "cycle counter increments per cycle")
        // Independent signal-quality stream: the two EEG-derived knobs are logged.
        XCTAssertEqual(first.temperature, 0.42, accuracy: 1e-9)
        XCTAssertEqual(first.styleInstruction, "Prefer common words.")
        // The input→output halves the diagnosis needs.
        XCTAssertTrue(first.prompt.contains("Prefer common words."),
                      "prompt (the 'what fed it' half) must be captured")
        XCTAssertEqual(first.generated, "a calm sentence",
                       "generated text (the 'what came out' half) must be captured")
        XCTAssertTrue(first.spoke, "a non-empty utterance must record spoke=true")
        XCTAssertNil(first.error, "a clean cycle must record no error")
    }

    func testProsodyTraceRecordsRequestedCadencePerPhrase() async {
        let generator = SpyGenerator(
            response: "Maybe this could work. This must clearly land.")
        let speaker = SpySpeaker()
        let prosodyTracer = SpyProsodyTraceLogger()
        let adaptation = GenerationAdaptation(
            maxCandidates: 3, temperature: 0.37, styleInstruction: "")
        let loop = SpokenGenerationLoop(
            generator: generator,
            speaker: speaker,
            adaptationProvider: { adaptation },
            config: fastConfig(),
            prosodyTracer: prosodyTracer
        )

        await loop.start()
        _ = await poll { await prosodyTracer.events.count >= 2 }
        await loop.stop()

        let events = await prosodyTracer.events
        XCTAssertGreaterThanOrEqual(events.count, 2)
        XCTAssertEqual(events[0].schemaVersion, ProsodyTraceEvent.currentSchemaVersion)
        XCTAssertEqual(events[0].sourceKind, "spoken-generation-requested-prosody")
        XCTAssertEqual(events[0].index, 0)
        XCTAssertEqual(events[1].index, 1)
        XCTAssertEqual(events[0].utteranceText, "Maybe this could work.")
        XCTAssertEqual(events[1].utteranceText, "This must clearly land.")
        XCTAssertEqual(events[0].voiceIdentifier, "spy-voice")
        XCTAssertEqual(events[0].synthesizerIdentifier, "stub")
        XCTAssertNil(events[0].predicted, "no learned cadence model has run yet")
        XCTAssertNil(events[0].measured, "requested-control trace is not acoustic measurement")
        XCTAssertEqual(events[0].dialogueState["cycle_index"] ?? -1, 0, accuracy: 0.0001)
        XCTAssertEqual(events[0].dialogueState["phrase_index"] ?? -1, 0, accuracy: 0.0001)
        XCTAssertEqual(events[0].dialogueState["temperature"] ?? -1, 0.37, accuracy: 0.0001)
        XCTAssertEqual(events[0].requested?.cadenceClass, "hedged")
        XCTAssertEqual(events[1].requested?.cadenceClass, "committed")
        XCTAssertLessThan(events[0].requested?.speechRate ?? 1,
                          events[1].requested?.speechRate ?? 0,
                          "hedged phrase should request a slower cadence")
        XCTAssertGreaterThan(events[0].requested?.hesitation ?? 0, 0)
        XCTAssertGreaterThan(events[1].requested?.emphasis ?? 0, 0)
    }

    func testTraceExposesStarvedSignatureIdenticalInputOutput() async {
        // A constant adaptation + canned generator is the *starved* case: every
        // cycle feeds an identical prompt and gets an identical output back. The
        // trace makes that visible (vs. a broken loop, which would carry an error).
        let generator = SpyGenerator(response: "same output")
        let speaker = SpySpeaker()
        let tracer = SpyTraceLogger()
        let loop = SpokenGenerationLoop(
            generator: generator, speaker: speaker,
            adaptationProvider: { .raw }, config: fastConfig(), tracer: tracer)
        await loop.start()
        _ = await poll { await tracer.events.count >= 3 }
        await loop.stop()

        let events = await tracer.events
        XCTAssertGreaterThanOrEqual(events.count, 3)
        XCTAssertEqual(Set(events.map(\.prompt)).count, 1,
                       "starved loop: prompt is identical across cycles")
        XCTAssertEqual(Set(events.map(\.generated)).count, 1,
                       "starved loop: generated output is identical across cycles")
        XCTAssertTrue(events.allSatisfy { $0.error == nil },
                      "starved is not broken: no cycle should carry an error")
    }

    func testTraceSurfacesSwallowedGenerationError() async {
        // The loop swallows non-cancellation generate/speak failures and retries.
        // Without the trace that *broken* case is invisible; with it, `error` is set.
        let speaker = SpySpeaker()
        let tracer = SpyTraceLogger()
        let loop = SpokenGenerationLoop(
            generator: BoomGenerator(), speaker: speaker,
            adaptationProvider: { .raw }, config: fastConfig(), tracer: tracer)
        await loop.start()
        _ = await poll { await tracer.events.count >= 1 }
        await loop.stop()

        let events = await tracer.events
        XCTAssertGreaterThanOrEqual(events.count, 1, "an erroring cycle must still emit a trace")
        let first = events[0]
        XCTAssertNotNil(first.error, "a swallowed generation error must be surfaced on the trace")
        XCTAssertTrue(first.error?.contains("boom") ?? false, "the error description is captured")
        XCTAssertNil(first.generated, "no text was produced, so generated is nil")
        XCTAssertFalse(first.spoke, "nothing was voiced on a failed cycle")
        let spokenCount = await speaker.spoken.count
        XCTAssertEqual(spokenCount, 0, "a broken generator must produce no speech")
    }

    func testTraceFlagsTrackActualExecutionNotIntent() async {
        // Generation succeeds but speech throws. The flags must reflect what
        // *happened*, not what was attempted: `generated` is captured (generation
        // ran), but `spoke` is false (nothing voiced to completion) and `error` is
        // set. A trace claiming spoke=true here would undercut the whole diagnostic.
        let tracer = SpyTraceLogger()
        let loop = SpokenGenerationLoop(
            generator: SpyGenerator(response: "a full sentence"),
            speaker: BoomSpeaker(),
            adaptationProvider: { .raw }, config: fastConfig(), tracer: tracer)
        await loop.start()
        _ = await poll { await tracer.events.count >= 1 }
        await loop.stop()

        let events = await tracer.events
        XCTAssertGreaterThanOrEqual(events.count, 1)
        let first = events[0]
        XCTAssertEqual(first.generated, "a full sentence",
                       "generation succeeded, so generated must be captured")
        XCTAssertFalse(first.spoke, "speech threw, so nothing was voiced to completion")
        XCTAssertNotNil(first.error, "the speech failure must be surfaced on the trace")
        XCTAssertTrue(first.error?.contains("boom") ?? false)
    }
}
