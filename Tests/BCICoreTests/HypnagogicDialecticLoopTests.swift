import XCTest
import Foundation
@testable import BCICore

/// Milestone 2 — the text-only dual-generation loop. Spies + an injected RNG
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
    /// calls — so a test can assert the finding is never spoken, that gating works,
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

    // MARK: - Witness (Reflective introspection) — see WITNESS.md

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
        // margin ⇒ metastable silence every turn — which must be broken by a cue.
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
                       "a stalemate voices neither pole — only the induction cue")
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
}
