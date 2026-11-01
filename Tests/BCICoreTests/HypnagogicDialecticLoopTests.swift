import XCTest
import Foundation
@testable import BCICore

/// Milestone 2 - the text-only dual-generation loop. Spies + an injected RNG
/// keep the single point of non-determinism under control, so loop-level
/// behavior (decisive resolution, bifurcation, input-silence cue, bounded
/// dialectical silence) is asserted deterministically.
final class HypnagogicDialecticLoopTests: XCTestCase {

    // MARK: - Spies

    private actor SpyListener: HypnagogicListening {
        nonisolated let isLive = false
        private var queue: [String?]
        private let loopLast: Bool
        private(set) var listenCount = 0
        private(set) var cancelCount = 0
        /// `loopLast`: once the script is drained, keep returning its last value
        /// (so a stalemate can repeat indefinitely for the silence test).
        init(script: [String?], loopLast: Bool = false) {
            self.queue = script
            self.loopLast = loopLast
        }
        func requestAuthorization() async -> Bool { true }
        func listen(timeout: TimeInterval) async throws -> String? {
            listenCount += 1
            if queue.count > 1 { return queue.removeFirst() }
            if let only = queue.first { return loopLast ? only : queue.removeFirst() }
            try? await Task.sleep(nanoseconds: 5_000_000)
            return nil
        }
        func cancel() async { cancelCount += 1 }
    }

    /// Returns one text for the low-temperature (coherence) role and another for
    /// the high-temperature (displacement) role, so the two candidates are
    /// distinguishable in the spoken output.
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

    /// Deterministic text → vector table; unknown text embeds to zero.
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

    private actor SpySpeaker: SpeechSynthesizing {
        nonisolated let isLive = false
        nonisolated let voiceIdentifier = "spy-voice"
        private(set) var spoken: [String] = []
        private(set) var stopCount = 0
        func speak(_ text: String) async throws { spoken.append(text) }
        func speak(_ text: String, prosody: SpeechProsody) async throws { spoken.append(text) }
        func stopSpeaking() async { stopCount += 1 }
    }

    private struct WitnessFailure: Error {}

    /// A witness generator that returns a fixed sentinel (or throws) and counts
    /// calls - so a test can assert the finding is never spoken, that gating works,
    /// and that a FAILING witness is still recorded as attempted.
    private actor WitnessSpy: TextGenerating {
        nonisolated let isLive = false
        nonisolated let modelIdentifier = "spy-witness"
        private let finding: String
        private let shouldThrow: Bool
        private(set) var callCount = 0
        init(finding: String, shouldThrow: Bool = false) {
            self.finding = finding; self.shouldThrow = shouldThrow
        }
        func generate(prompt: String, maxTokens: Int, temperature: Double,
                      cancellationID: UUID) async throws -> String {
            callCount += 1
            if shouldThrow { throw WitnessFailure() }
            return finding
        }
    }

    private actor CapturingTurnLogger: DialecticalTurnLogging {
        private(set) var events: [DialecticalTurnEvent] = []
        func log(_ event: DialecticalTurnEvent) async { events.append(event) }
    }

    private actor CapturingProsodyLogger: ProsodyTraceLogging {
        private(set) var events: [ProsodyTraceEvent] = []
        func log(_ event: ProsodyTraceEvent) async { events.append(event) }
    }

    /// A metadata-publishing generator - the shape
    /// `GenerationRuntimeTextGeneratingAdapter` has in production: a struct
    /// whose callback lives in a shared class box, returning
    /// role-distinguishable text and firing `onMetadata` with a fixed
    /// identity after every call.
    private struct PublishingSpyGenerator: MetadataPublishingTextGenerating {
        private final class CallbackBox: @unchecked Sendable {
            var callback: (@Sendable (GenerationMetadata) -> Void)?
        }
        nonisolated let isLive = false
        nonisolated let modelIdentifier: String
        private let stabilizer: String
        private let dreamer: String
        private let metadata: GenerationMetadata
        private let box = CallbackBox()
        var onMetadata: (@Sendable (GenerationMetadata) -> Void)? {
            get { box.callback }
            set { box.callback = newValue }
        }
        init(stabilizer: String, dreamer: String? = nil, metadata: GenerationMetadata) {
            self.stabilizer = stabilizer
            self.dreamer = dreamer ?? stabilizer
            self.metadata = metadata
            self.modelIdentifier = metadata.model
        }
        func generate(prompt: String, maxTokens: Int, temperature: Double,
                      cancellationID: UUID) async throws -> String {
            box.callback?(metadata)
            return temperature >= 0.9 ? dreamer : stabilizer
        }
    }

    private func spyMetadata(profile: String, hash: String) -> GenerationMetadata {
        GenerationMetadata(runtime: "spy", transport: "spy", provider: "spy",
                           model: "spy-model", promptHash: hash,
                           promptProfile: profile, interactionStyle: "dialectical")
    }

    private func fastConfig(maxSilence: Int = 3, witnessEnabled: Bool = false) -> HypnagogicDialecticLoop.Config {
        HypnagogicDialecticLoop.Config(listenTimeout: 0.01, interTurnDelayNanos: 1_000,
                                       maxConsecutiveSilence: maxSilence,
                                       witnessEnabled: witnessEnabled)
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

    // MARK: - Witness (Reflective introspection) - see WITNESS.md

    func testWitnessFiresForReflectiveButIsNeverSpoken() async {
        // The firewall invariant: the witness observes, its finding is recorded in
        // telemetry, but it never reaches the speaker.
        let embedder = MapEmbedder(dimension: 2, table: [
            "the sea": [1, 0], "calm sea": [1, 0], "moon river": [0, 1],
            "WITNESS_UNSPOKEN": [0.7, 0.7],
        ])
        let listener = SpyListener(script: ["the sea"], loopLast: true)
        let generator = TwoRoleGenerator(stabilizer: "calm sea", dreamer: "moon river")
        let witness = WitnessSpy(finding: "WITNESS_UNSPOKEN")
        let speaker = SpySpeaker()
        let logger = CapturingTurnLogger()
        let loop = HypnagogicDialecticLoop(
            listener: listener, generator: generator, speaker: speaker, embedder: embedder,
            random: { 0.5 }, turnLogger: logger, witness: witness,
            config: fastConfig(witnessEnabled: true))
        await loop.start()
        let ok = await poll {
            let c = await witness.callCount
            let e = await logger.events.count
            return c >= 1 && e >= 1
        }
        await loop.stop()
        XCTAssertTrue(ok, "the witness must fire when enabled")
        let spoken = await speaker.spoken.joined(separator: " ")
        XCTAssertFalse(spoken.contains("WITNESS_UNSPOKEN"), "the witness finding is NEVER voiced")
        let events = await logger.events
        let ev = events.first { $0.witnessFinding != nil }
        XCTAssertEqual(ev?.witnessFinding, "WITNESS_UNSPOKEN", "the finding is recorded in telemetry")
        XCTAssertNotNil(ev?.witnessDistance, "witnessDistance is computed against the spoken text")
    }

    func testWitnessNeverCalledWhenDisabled() async {
        // Gating: even with a witness injected, witnessEnabled=false (Focused/
        // default) must never call it and must log no finding.
        let embedder = MapEmbedder(dimension: 2, table: ["the sea": [1, 0], "calm sea": [1, 0], "moon river": [0, 1]])
        let listener = SpyListener(script: ["the sea"], loopLast: true)
        let generator = TwoRoleGenerator(stabilizer: "calm sea", dreamer: "moon river")
        let witness = WitnessSpy(finding: "SHOULD_NOT_FIRE")
        let speaker = SpySpeaker()
        let logger = CapturingTurnLogger()
        let loop = HypnagogicDialecticLoop(
            listener: listener, generator: generator, speaker: speaker, embedder: embedder,
            random: { 0.5 }, turnLogger: logger, witness: witness,
            config: fastConfig(witnessEnabled: false))
        await loop.start()
        let ran = await poll { (await logger.events.count) >= 2 }
        await loop.stop()
        XCTAssertTrue(ran, "loop ran turns")
        let calls = await witness.callCount
        XCTAssertEqual(calls, 0, "witness must NOT be called when disabled")
        let events = await logger.events
        let anyFinding = events.contains { $0.witnessFinding != nil }
        XCTAssertFalse(anyFinding, "no witnessFinding logged when disabled")
    }

    func testFailingWitnessIsAttemptedButProducesNoFinding() async {
        // A witness that throws every turn must NOT break the loop, but must be
        // distinguishable from a disabled one: witnessAttempted=true, finding=nil,
        // and the turn still speaks. (Otherwise a broken Reflective run masquerades
        // as Focused in the rollup.)
        let embedder = MapEmbedder(dimension: 2, table: ["the sea": [1, 0], "calm sea": [1, 0], "moon river": [0, 1]])
        let listener = SpyListener(script: ["the sea"], loopLast: true)
        let generator = TwoRoleGenerator(stabilizer: "calm sea", dreamer: "moon river")
        let witness = WitnessSpy(finding: "UNUSED", shouldThrow: true)
        let speaker = SpySpeaker()
        let logger = CapturingTurnLogger()
        let loop = HypnagogicDialecticLoop(
            listener: listener, generator: generator, speaker: speaker, embedder: embedder,
            random: { 0.5 }, turnLogger: logger, witness: witness,
            config: fastConfig(witnessEnabled: true))
        await loop.start()
        let ok = await poll {
            let c = await witness.callCount
            let s = await speaker.spoken.count
            return c >= 1 && s >= 1
        }
        await loop.stop()
        XCTAssertTrue(ok, "the turn still speaks even though the witness fails")
        let events = await logger.events
        let ev = events.first { $0.witnessAttempted == true }
        XCTAssertNotNil(ev, "witnessAttempted is true even when the call throws")
        XCTAssertNil(ev?.witnessFinding, "a failed witness produces no finding")
    }

    // MARK: - Witness fingerprint (per-turn Witness provenance)

    func testPoleAndWitnessFingerprintsAreCapturedSeparately() async {
        // The persisted turn must independently attest which runtime/prompt
        // produced the Witness finding - not only the candidates'. The bug
        // class this guards: a "Witness" adapter that reported one prompt
        // while transmitting another. Distinct prompt hashes on the two
        // fingerprints of the same event are the proof the wiring is per-role.
        let embedder = MapEmbedder(dimension: 2, table: [
            "the sea": [1, 0], "calm sea": [1, 0], "moon river": [0, 1],
            "WITNESS_FINDING": [0.7, 0.7],
        ])
        let listener = SpyListener(script: ["the sea"], loopLast: true)
        let generator = PublishingSpyGenerator(
            stabilizer: "calm sea", dreamer: "moon river",
            metadata: spyMetadata(profile: "wakingDialectical", hash: "pole-hash"))
        let witness = PublishingSpyGenerator(
            stabilizer: "WITNESS_FINDING",
            metadata: spyMetadata(profile: "witness", hash: "witness-hash"))
        let speaker = SpySpeaker()
        let logger = CapturingTurnLogger()
        let loop = HypnagogicDialecticLoop(
            listener: listener, generator: generator, speaker: speaker, embedder: embedder,
            random: { 0.5 }, turnLogger: logger, witness: witness,
            config: fastConfig(witnessEnabled: true))
        await loop.attachMetadataCaptureFromAdapter()
        await loop.start()
        let ok = await poll {
            let events = await logger.events
            return events.contains { $0.witnessGeneratorFingerprint != nil }
        }
        await loop.stop()
        XCTAssertTrue(ok, "a reflective turn must record the Witness fingerprint")

        let events = await logger.events
        let ev = events.first { $0.witnessGeneratorFingerprint != nil }
        XCTAssertEqual(ev?.generatorFingerprint?.promptHash, "pole-hash")
        XCTAssertEqual(ev?.witnessGeneratorFingerprint?.promptHash, "witness-hash")
        XCTAssertNotEqual(
            ev?.generatorFingerprint?.promptHash,
            ev?.witnessGeneratorFingerprint?.promptHash,
            "the Witness fingerprint must not attest the pole prompt")
        XCTAssertEqual(ev?.witnessGeneratorFingerprint?.promptProfile, "witness")
    }

    func testWitnessFingerprintIsNilWhenWitnessDisabled() async {
        // Focused/Contemplative: even with a publishing witness *injected*,
        // a profile that disables it must not attest a Witness identity  - 
        // the fingerprint records what generated, not what was available.
        let embedder = MapEmbedder(
            dimension: 2, table: ["the sea": [1, 0], "calm sea": [1, 0], "moon river": [0, 1]])
        let listener = SpyListener(script: ["the sea"], loopLast: true)
        let generator = PublishingSpyGenerator(
            stabilizer: "calm sea", dreamer: "moon river",
            metadata: spyMetadata(profile: "wakingDialectical", hash: "pole-hash"))
        let witness = PublishingSpyGenerator(
            stabilizer: "SHOULD_NOT_FIRE",
            metadata: spyMetadata(profile: "witness", hash: "witness-hash"))
        let speaker = SpySpeaker()
        let logger = CapturingTurnLogger()
        let loop = HypnagogicDialecticLoop(
            listener: listener, generator: generator, speaker: speaker, embedder: embedder,
            random: { 0.5 }, turnLogger: logger, witness: witness,
            config: fastConfig(witnessEnabled: false))
        await loop.attachMetadataCaptureFromAdapter()
        await loop.start()
        let ok = await poll {
            let events = await logger.events
            return events.contains { $0.generatorFingerprint != nil }
        }
        await loop.stop()
        XCTAssertTrue(ok, "the pole fingerprint must still be captured")

        let events = await logger.events
        let ev = events.first { $0.generatorFingerprint != nil }
        XCTAssertEqual(ev?.generatorFingerprint?.promptHash, "pole-hash")
        XCTAssertNil(
            ev?.witnessGeneratorFingerprint,
            "a turn on which the Witness never ran must not attest a Witness identity")
    }

    func testSelfSimilarityRisesWhenRepliesCollapse() async {
        // The reflexive metric: the same coherent reply wins every turn ⇒ the
        // utterance sits on its own reply centroid ⇒ selfSimilarity → 1. Logged
        // for every profile, independent of the witness.
        let embedder = MapEmbedder(dimension: 2, table: ["the sea": [1, 0], "calm sea": [1, 0], "moon river": [0, 1]])
        let listener = SpyListener(script: ["the sea"], loopLast: true)
        let generator = TwoRoleGenerator(stabilizer: "calm sea", dreamer: "moon river")
        let speaker = SpySpeaker()
        let logger = CapturingTurnLogger()
        let loop = HypnagogicDialecticLoop(
            listener: listener, generator: generator, speaker: speaker, embedder: embedder,
            random: { 0.5 }, turnLogger: logger, config: fastConfig())
        await loop.start()
        let ok = await poll { (await logger.events.count) >= 3 }
        await loop.stop()
        XCTAssertTrue(ok)
        let events = await logger.events
        XCTAssertNil(events[0].selfSimilarity, "first turn has no reply centroid yet")
        XCTAssertGreaterThan(events[1].selfSimilarity ?? 0, 0.9, "collapse onto the own centroid ⇒ ~1")
    }

    func testOldDialecticTurnLogWithoutWitnessFieldsStillDecodes() throws {
        // Backward-compat: a pre-witness log line (no witness/self-similarity keys)
        // must still decode, with the new fields nil.
        let json = Data("""
        {"index":0,"heard":"x","candidates":[],"tension":0.1,"margin":0.0,
         "selectionTemperature":1.0,"glossScalar":0.5,"outcome":"silent"}
        """.utf8)
        let ev = try JSONDecoder().decode(DialecticalTurnEvent.self, from: json)
        XCTAssertNil(ev.witnessFinding)
        XCTAssertNil(ev.witnessDistance)
        XCTAssertNil(ev.selfSimilarity)
        XCTAssertNil(ev.spokenText)
        XCTAssertNil(ev.runID)
        XCTAssertNil(ev.recordedAt)
    }

    func testTurnsCarryTheirLoopsRunIDAndATimestamp() async throws {
        // The app rebuilds the loop on every mode switch and `index` restarts at
        // 0, so a day's log needs `runID` to tell runs apart, and `recordedAt`
        // to order them.
        let embedder = MapEmbedder(
            dimension: 2, table: ["the sea": [1, 0], "calm sea": [1, 0], "moon river": [0, 1]])
        let logger = CapturingTurnLogger()
        func makeLoop() -> HypnagogicDialecticLoop {
            HypnagogicDialecticLoop(
                listener: SpyListener(script: ["the sea"], loopLast: true),
                generator: TwoRoleGenerator(stabilizer: "calm sea", dreamer: "moon river"),
                speaker: SpySpeaker(), embedder: embedder,
                random: { 0.5 }, turnLogger: logger, config: fastConfig())
        }
        let first = makeLoop()
        let second = makeLoop()
        XCTAssertNotEqual(first.runID, second.runID, "each loop instance is its own run")

        await first.start()
        let ok = await poll { await !logger.events.isEmpty }
        await first.stop()
        XCTAssertTrue(ok)

        let events = await logger.events
        let ev = try XCTUnwrap(events.first)
        XCTAssertEqual(ev.runID, first.runID)
        let stamp = try XCTUnwrap(ev.recordedAt)
        XCTAssertNoThrow(try Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(stamp))
        // Plain encoder/decoder (the harness and tests) round-trip both fields.
        let decoded = try JSONDecoder().decode(DialecticalTurnEvent.self, from: JSONEncoder().encode(ev))
        XCTAssertEqual(decoded.runID, ev.runID)
        XCTAssertEqual(decoded.recordedAt, ev.recordedAt)
    }

    // MARK: - Conversation history

    private let historyTable: [String: [Float]] = [
        "the sea": [1, 0], "second line": [1, 0], "calm sea": [1, 0], "moon river": [0, 1]]

    /// Runs `heard` through a fresh loop sharing `history`, returning the
    /// generator's prompts and the voiced reply of each turn.
    private func run(_ heard: [String], history: ConversationHistory? = nil,
                     config: HypnagogicDialecticLoop.Config? = nil) async -> (prompts: [String], spoken: [String?]) {
        let generator = TwoRoleGenerator(stabilizer: "calm sea", dreamer: "moon river")
        let logger = CapturingTurnLogger()
        let loop = HypnagogicDialecticLoop(
            listener: SpyListener(script: heard.map { $0 }), generator: generator,
            speaker: SpySpeaker(), embedder: MapEmbedder(dimension: 2, table: historyTable),
            random: { 0.5 }, turnLogger: logger, config: config ?? fastConfig(), history: history)
        await loop.start()
        _ = await poll { await logger.events.count >= heard.count }
        await loop.stop()
        return (await generator.prompts, await logger.events.map(\.spokenText))
    }

    /// Oct 13: "reiterate on that framework" was answered with "don't reiterate
    /// the framework at all", because each voice saw only the latest utterance.
    /// From the second turn on, both voices see what was heard and voiced before.
    func testVoicesSeeTheEarlierExchange() async throws {
        let (prompts, spoken) = await run(["the sea", "second line"])
        XCTAssertEqual(prompts.count, 4, "two voices × two turns")
        let firstReply = try XCTUnwrap(spoken.first ?? nil)
        for prompt in prompts[2...3] {
            XCTAssertTrue(prompt.contains("the sea"), "earlier heard text missing:\n\(prompt)")
            XCTAssertTrue(prompt.contains(firstReply), "earlier reply missing:\n\(prompt)")
            XCTAssertTrue(prompt.contains("second line"), "the current utterance must still be there")
        }
        XCTAssertFalse(prompts[0].contains("calm sea") || prompts[0].contains("moon river"),
                       "the first turn has no history to show")
    }

    /// The app rebuilds the loop on every mode switch; a shared history carries
    /// the thread into the new instance.
    func testSharedHistoryCarriesIntoANewLoopInstance() async {
        let history = ConversationHistory()
        _ = await run(["the sea"], history: history)
        let (prompts, _) = await run(["second line"], history: history)
        XCTAssertTrue(prompts.first?.contains("the sea") == true,
                      "a rebuilt loop must see the earlier exchange:\n\(prompts.first ?? "")")
    }

    func testHistoryPreambleKeepsSilentTurnsOldestFirst() {
        let preamble = HypnagogicDialecticLoop.historyPreamble([
            .init(heard: "all right", spoken: nil),
            .init(heard: "the sea", spoken: "calm sea"),
        ])
        XCTAssertTrue(preamble.contains("They said: all right\nYou stayed silent.\nThey said: the sea\nYou replied: calm sea"),
                      "silent turn kept, oldest first:\n\(preamble)")
        XCTAssertTrue(preamble.hasSuffix("\n\n"), "the role prompt must start on its own paragraph")
    }

    func testZeroHistoryExchangesSendsOnlyTheCurrentUtterance() async {
        var config = fastConfig()
        config.historyExchanges = 0
        let (prompts, _) = await run(["the sea", "second line"], config: config)
        XCTAssertEqual(prompts.count, 4)
        XCTAssertFalse(prompts[2].contains("the sea"))
        XCTAssertFalse(prompts[3].contains("the sea"))
    }

    // MARK: - Tests

    func testHeardDrivesBothRolesThenSpeaksTheDecisiveBasin() async {
        // heard ≈ stabilizer candidate ⇒ stabilizer wins decisively regardless of draw.
        let embedder = MapEmbedder(dimension: 2, table: [
            "the sea": [1, 0], "calm sea": [1, 0], "moon river": [0, 1],
        ])
        let listener = SpyListener(script: ["the sea"])
        let generator = TwoRoleGenerator(stabilizer: "calm sea", dreamer: "moon river")
        let speaker = SpySpeaker()
        let loop = HypnagogicDialecticLoop(
            listener: listener, generator: generator, speaker: speaker, embedder: embedder,
            random: { 0.5 }, config: fastConfig()
        )
        await loop.start()
        let ok = await poll {
            let g = await generator.prompts.count
            let s = await speaker.spoken.count
            return g >= 2 && s >= 1
        }
        XCTAssertTrue(ok, "both roles must generate, then the winner is spoken")
        let spoken = await speaker.spoken.joined(separator: " ")
        XCTAssertTrue(spoken.contains("calm sea"), "the coherent basin wins when heard matches it")
        XCTAssertFalse(spoken.contains("moon river"), "only the chosen basin is voiced")
        await loop.stop()
    }

    func testDialecticLoopLogsTurnIndexedRequestedProsody() async {
        let embedder = MapEmbedder(dimension: 2, table: [
            "the sea": [1, 0], "calm sea": [1, 0], "moon river": [0, 1],
        ])
        let listener = SpyListener(script: ["the sea"])
        let generator = TwoRoleGenerator(stabilizer: "calm sea", dreamer: "moon river")
        let speaker = SpySpeaker()
        let turnLogger = CapturingTurnLogger()
        let prosodyLogger = CapturingProsodyLogger()
        let loop = HypnagogicDialecticLoop(
            listener: listener,
            generator: generator,
            speaker: speaker,
            embedder: embedder,
            random: { 0.5 },
            turnLogger: turnLogger,
            prosodyTracer: prosodyLogger,
            config: fastConfig()
        )

        await loop.start()
        let ok = await poll {
            let turnCount = await turnLogger.events.count
            let prosodyCount = await prosodyLogger.events.count
            return turnCount >= 1 && prosodyCount >= 1
        }
        await loop.stop()

        XCTAssertTrue(ok, "voiced dialectical turns should emit matching turn and prosody traces")
        let turns = await turnLogger.events
        let prosody = await prosodyLogger.events
        XCTAssertEqual(turns.first?.index, 0)
        XCTAssertEqual(prosody.first?.index, 0)
        XCTAssertEqual(prosody.first?.sourceKind, "dialectical-turn-requested-prosody")
        XCTAssertEqual(prosody.first?.utteranceText, turns.first?.spokenText)
        XCTAssertEqual(prosody.first?.dialogueState["turn_index"], 0)
        XCTAssertNotNil(prosody.first?.requested)
        XCTAssertNil(prosody.first?.measured, "the dialectical hook records requested controls, not measured audio")
        XCTAssertEqual(prosody.first?.voiceIdentifier, "spy-voice")
        XCTAssertEqual(prosody.first?.synthesizerIdentifier, "stub")
    }

    func testNearEquilibriumTheDrawTipsWhichBasinIsSpoken() async {
        // Two equal-potential, low-tension candidates: only the injected draw differs.
        let table: [String: [Float]] = ["x": [0, 1], "AAA": [1, 0], "BBB": [1, 0]]
        func makeLoop(draw: Double, speaker: SpySpeaker) -> HypnagogicDialecticLoop {
            HypnagogicDialecticLoop(
                listener: SpyListener(script: ["x"]),
                generator: TwoRoleGenerator(stabilizer: "AAA", dreamer: "BBB"),
                speaker: speaker, embedder: MapEmbedder(dimension: 2, table: table),
                random: { draw }, config: fastConfig()
            )
        }
        let sLow = SpySpeaker(); let low = makeLoop(draw: 0.01, speaker: sLow)
        let sHigh = SpySpeaker(); let high = makeLoop(draw: 0.99, speaker: sHigh)
        await low.start(); await high.start()
        _ = await poll {
            let a = await sLow.spoken.count
            let b = await sHigh.spoken.count
            return a >= 1 && b >= 1
        }
        let lowSpoke = await sLow.spoken.joined(separator: " ")
        let highSpoke = await sHigh.spoken.joined(separator: " ")
        XCTAssertTrue(lowSpoke.contains("AAA"), "a low draw lands in the first basin")
        XCTAssertTrue(highSpoke.contains("BBB"), "a high draw lands in the other basin")
        await low.stop(); await high.stop()
    }

    func testEmptyListenSpeaksCueWithoutGenerating() async {
        let embedder = MapEmbedder(dimension: 2, table: [:])
        let listener = SpyListener(script: [nil])
        let generator = TwoRoleGenerator(stabilizer: "S", dreamer: "D")
        let speaker = SpySpeaker()
        let loop = HypnagogicDialecticLoop(
            listener: listener, generator: generator, speaker: speaker, embedder: embedder,
            random: { 0.5 }, config: fastConfig()
        )
        await loop.start()
        let spoke = await poll { await speaker.spoken.count >= 1 }
        XCTAssertTrue(spoke, "an empty listen turn must still speak an induction cue")
        let called = await generator.prompts.count
        XCTAssertEqual(called, 0, "an empty *input* turn must NOT call the (possibly cloud) model")
        await loop.stop()
    }

    func testDialecticalSilenceIsBoundedByACue() async {
        // heard orthogonal to both poles, poles antipodal ⇒ high tension + zero
        // margin ⇒ metastable silence every turn - which must be broken by a cue.
        // Candidate texts chosen so they can't appear as substrings of any cue.
        let embedder = MapEmbedder(dimension: 2, table: [
            "x": [0, 1], "poleAlpha": [1, 0], "poleOmega": [-1, 0],
        ])
        let listener = SpyListener(script: ["x"], loopLast: true)
        let generator = TwoRoleGenerator(stabilizer: "poleAlpha", dreamer: "poleOmega")
        let speaker = SpySpeaker()
        let loop = HypnagogicDialecticLoop(
            listener: listener, generator: generator, speaker: speaker, embedder: embedder,
            random: { 0.5 }, config: fastConfig(maxSilence: 2)
        )
        await loop.start()
        // Both roles generate (so this is dialectical silence, not input silence)…
        let generated = await poll { await generator.prompts.count >= 2 }
        XCTAssertTrue(generated, "the turn ran the competition")
        // …yet the candidate texts are never voiced; only a bounded cue is.
        let brokeSilence = await poll { await speaker.spoken.count >= 1 }
        XCTAssertTrue(brokeSilence, "a run of stalemates must eventually be broken by a cue")
        let spoken = await speaker.spoken.joined(separator: " ")
        XCTAssertFalse(spoken.contains("poleAlpha") || spoken.contains("poleOmega"),
                       "a stalemate voices neither pole - only the induction cue")
        await loop.stop()
    }

    func testStopHaltsCancelsListenerAndInterruptsSpeech() async {
        let embedder = MapEmbedder(dimension: 2, table: ["one": [1, 0], "r": [1, 0]])
        let listener = SpyListener(script: ["one"])
        let generator = TwoRoleGenerator(stabilizer: "r", dreamer: "r2")
        let speaker = SpySpeaker()
        let loop = HypnagogicDialecticLoop(
            listener: listener, generator: generator, speaker: speaker, embedder: embedder,
            random: { 0.5 }, config: fastConfig()
        )
        await loop.start()
        _ = await poll { await speaker.spoken.count >= 1 }
        await loop.stop()
        let running = await loop.isRunning
        XCTAssertFalse(running, "isRunning must be false after stop()")
        let cancels = await listener.cancelCount
        XCTAssertGreaterThanOrEqual(cancels, 1, "stop() must cancel the listener")
        let stops = await speaker.stopCount
        XCTAssertGreaterThanOrEqual(stops, 1, "stop() must interrupt the speaker")
    }

    func testStatusReportsProgressAndStoppedLifecycle() async {
        let embedder = MapEmbedder(dimension: 2, table: [
            "one": [1, 0], "stable": [1, 0], "dream": [0, 1],
        ])
        let loop = HypnagogicDialecticLoop(
            listener: SpyListener(script: ["one"], loopLast: true),
            generator: TwoRoleGenerator(stabilizer: "stable", dreamer: "dream"),
            speaker: SpySpeaker(),
            embedder: embedder,
            random: { 0.5 },
            config: fastConfig()
        )

        let initial = await loop.status
        XCTAssertEqual(initial.phase, .stopped)
        XCTAssertEqual(initial.turnIndex, 0)

        await loop.start()
        let didCompleteTurn = await poll { (await loop.status).turnIndex >= 1 }
        XCTAssertTrue(didCompleteTurn, "a successful turn must be visible in loop status")

        let active = await loop.status
        XCTAssertNotEqual(active.phase, .stopped)
        XCTAssertNil(active.lastFailure)
        XCTAssertNotNil(active.lastTurnAt)

        await loop.stop()
        let stopped = await loop.status
        XCTAssertEqual(stopped.phase, .stopped)
        XCTAssertGreaterThanOrEqual(stopped.turnIndex, 1)
    }

    func testSanitizeGeneratedCandidateStripsPromptEchoFromSmallModels() {
        let heard = "Answer the question what are your capabilities as Qwen"
        let echoedOnly = "In a live dialogue, the other person just said: \"\(heard)\""
        XCTAssertEqual(HypnagogicDialecticLoop.sanitizeGeneratedCandidate(echoedOnly, heard: heard), "",
                       "a candidate that only repeats the prompt prefix must reduce to empty string")

        let echoedWithAnswer = "In a live dialogue, the other person just said: \"\(heard)\" Your capabilities as Qwen can be vast and diverse."
        XCTAssertEqual(HypnagogicDialecticLoop.sanitizeGeneratedCandidate(echoedWithAnswer, heard: heard),
                       "Your capabilities as Qwen can be vast and diverse.",
                       "echoed prefix must be stripped while preserving the substantive completion")
    }

    func testClassifyDiscourseSeparatesBackchannelsAmbientRoomAndDirectAddress() {
        XCTAssertEqual(HypnagogicDialecticLoop.classifyDiscourse("Yeah"), .ambientBackchannel)
        XCTAssertEqual(HypnagogicDialecticLoop.classifyDiscourse("Oh my God"), .ambientBackchannel)
        XCTAssertEqual(HypnagogicDialecticLoop.classifyDiscourse("Yeah I was I wasn't"), .ambientBackchannel)
        XCTAssertEqual(HypnagogicDialecticLoop.classifyDiscourse("Right"), .ambientBackchannel)
        XCTAssertEqual(
            HypnagogicDialecticLoop.classifyDiscourse("Sinking warm and slow let the shapes dissolve and float away"),
            .ambientBackchannel,
            "Acoustic loopback of silenceCue must be suppressed as ambientBackchannel"
        )
        XCTAssertEqual(
            HypnagogicDialecticLoop.classifyDiscourse("Please bring the item to the table"),
            .ambientBackchannel
        )
        XCTAssertEqual(
            HypnagogicDialecticLoop.classifyDiscourse("Set a timer for ten minutes"),
            .ambientBackchannel
        )
        XCTAssertEqual(HypnagogicDialecticLoop.classifyDiscourse("Stop"), .ambientBackchannel)
        XCTAssertEqual(
            HypnagogicDialecticLoop.classifyDiscourse("I was talking with a colleague while we were working"),
            .ambientRoomConversation
        )
        XCTAssertEqual(
            HypnagogicDialecticLoop.classifyDiscourse("Does my friend model hypotheses have any relation to equifinality"),
            .directAddress
        )
    }

    func testAmbientBackchannelLogsSilentTurnWithoutCallingGenerator() async {
        let embedder = MapEmbedder(dimension: 2, table: [:])
        let listener = SpyListener(script: ["Oh my God"], loopLast: true)
        let generator = TwoRoleGenerator(stabilizer: "S", dreamer: "D")
        let speaker = SpySpeaker()
        let logger = CapturingTurnLogger()
        let loop = HypnagogicDialecticLoop(
            listener: listener, generator: generator, speaker: speaker, embedder: embedder,
            random: { 0.5 }, turnLogger: logger, config: fastConfig()
        )
        await loop.start()
        let logged = await poll { await logger.events.count >= 1 }
        await loop.stop()
        XCTAssertTrue(logged, "ambient backchannel must log a silent turn")
        let called = await generator.prompts.count
        XCTAssertEqual(called, 0, "ambient backchannel must not invoke the generator")
        let spokenCount = await speaker.spoken.count
        XCTAssertEqual(spokenCount, 0, "ambient backchannel must not speak over room conversation")
    }

    func testFourPillarHUDAndDirectRecallQueriesInjectContextAndSelectCoherenceDeterministically() async {
        let hudUtterance = "What is the fast wire frame slow core hollow shell gold flux edge cycle invert cycle used for"
        XCTAssertTrue(HypnagogicDialecticLoop.isFourPillarHUDQuery(hudUtterance))
        XCTAssertTrue(HypnagogicDialecticLoop.isDirectRecallOrClarificationQuery(hudUtterance))

        let recallUtterance = "You said lemon juice or what else if not that then solder or steel wool"
        XCTAssertFalse(HypnagogicDialecticLoop.isFourPillarHUDQuery(recallUtterance))
        XCTAssertTrue(HypnagogicDialecticLoop.isDirectRecallOrClarificationQuery(recallUtterance))

        let embedder = MapEmbedder(dimension: 2, table: [
            hudUtterance: [1, 0],
            "CoherenceHUD": [0.95, 0.31],
            "DisplacementHUD": [0.92, 0.39]
        ])
        let listener = SpyListener(script: [hudUtterance], loopLast: true)
        let generator = TwoRoleGenerator(stabilizer: "CoherenceHUD", dreamer: "DisplacementHUD")
        let speaker = SpySpeaker()
        let logger = CapturingTurnLogger()
        let loop = HypnagogicDialecticLoop(
            listener: listener, generator: generator, speaker: speaker, embedder: embedder,
            random: { 0.99 }, turnLogger: logger, config: fastConfig()
        )
        await loop.start()
        let logged = await poll { await logger.events.count >= 1 }
        await loop.stop()
        XCTAssertTrue(logged)

        let prompts = await generator.prompts
        XCTAssertTrue(prompts.first?.contains("[NeuralCompose 4-Pillar 3D/4D Viewport Reference:") == true,
                      "HUD query must inject the 4-Pillar Viewport architectural reference into the turn preamble")
        let event = await logger.events.first
        XCTAssertEqual(event?.outcome, "spoke:coherence-seeking",
                       "Direct recall / HUD queries must deterministically select coherence-seeking even when RNG draw is 0.99")
    }

    func testBluetoothBrainFlowQueryAndMemoryResetAutoforgetBehavior() async {
        let btUtterance = "Should we test out the Bluetooth muse BCI brain computer interface EEG connection to NeuralCompose"
        XCTAssertTrue(HypnagogicDialecticLoop.isBluetoothBrainFlowOrStackQuery(btUtterance))
        XCTAssertTrue(HypnagogicDialecticLoop.isDirectRecallOrClarificationQuery(btUtterance))

        XCTAssertTrue(HypnagogicDialecticLoop.isMemoryResetCommand("Turn off"))
        XCTAssertTrue(HypnagogicDialecticLoop.isMemoryResetCommand("Forget that"))
        XCTAssertEqual(HypnagogicDialecticLoop.classifyDiscourse("Sex sex sex"), .ambientBackchannel)
        XCTAssertEqual(HypnagogicDialecticLoop.classifyDiscourse("Kind of"), .ambientBackchannel)
        XCTAssertEqual(HypnagogicDialecticLoop.classifyDiscourse("OK I should be good I'll be down in a second"), .ambientBackchannel)

        let embedder = MapEmbedder(dimension: 2, table: [
            btUtterance: [1, 0],
            "CoherenceBLE": [0.96, 0.28],
            "DisplacementBLE": [0.91, 0.41]
        ])
        let listener = SpyListener(script: ["Turn off", btUtterance], loopLast: true)
        let generator = TwoRoleGenerator(stabilizer: "CoherenceBLE", dreamer: "DisplacementBLE")
        let speaker = SpySpeaker()
        let logger = CapturingTurnLogger()
        let history = ConversationHistory()
        history.append(heard: "stale-1", spoken: "stale-reply-1")
        history.append(heard: "stale-2", spoken: "stale-reply-2")
        history.append(heard: "stale-3", spoken: "stale-reply-3")

        let loop = HypnagogicDialecticLoop(
            listener: listener, generator: generator, speaker: speaker, embedder: embedder,
            random: { 0.99 }, turnLogger: logger, config: fastConfig(), history: history
        )
        await loop.start()
        let logged = await poll { await logger.events.count >= 2 }
        await loop.stop()
        XCTAssertTrue(logged)

        let events = await logger.events
        XCTAssertEqual(events.first?.outcome, "silent", "Memory reset command 'Turn off' must log a silent turn without speaking")
        XCTAssertEqual(events.dropFirst().first?.outcome, "spoke:coherence-seeking",
                       "Bluetooth/BrainFlow query must deterministically select coherence-seeking")
        let prompts = await generator.prompts
        XCTAssertTrue(prompts.first?.contains("[NeuralCompose Bluetooth, BrainFlow, and Polyglot Stack Reference") == true,
                      "Bluetooth/BrainFlow query must inject the Bluetooth/BrainFlow/Julia/Python/Swift reference preamble")
        XCTAssertFalse(prompts.first?.contains("stale-1") == true,
                       "Memory reset command must trim oldest conversation history turns via autoforgetting")
    }
}
