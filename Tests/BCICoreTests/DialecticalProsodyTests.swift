import XCTest
import Foundation
@testable import BCICore

/// Milestone 4 — prosody coupling. The blend math is pure; the loop test proves
/// the spoken voice leans toward whichever pole won the competition.
final class DialecticalProsodyTests: XCTestCase {

    // MARK: - Pure blend

    func testBlendAtEndpointsReturnsEachVoice() {
        let stab = SpeechProsody.hypnagogicStabilizer
        let dream = SpeechProsody.hypnagogicDreamer
        let allStab = SpeechProsody.blend([(stab, 1), (dream, 0)])
        let allDream = SpeechProsody.blend([(stab, 0), (dream, 1)])
        XCTAssertEqual(allStab.pitchMultiplier, stab.pitchMultiplier)
        XCTAssertEqual(allDream.pitchMultiplier, dream.pitchMultiplier)
        XCTAssertEqual(allDream.rate, dream.rate)
    }

    func testBlendInterpolatesProportionally() {
        let mid = SpeechProsody.blend([(.hypnagogicStabilizer, 1), (.hypnagogicDreamer, 1)])
        XCTAssertEqual(mid.rate ?? 0, (0.35 + 0.42) / 2, accuracy: 1e-5)
        XCTAssertEqual(mid.pitchMultiplier ?? 0, (0.8 + 0.98) / 2, accuracy: 1e-5)
    }

    func testNilFieldsAbstainAndZeroWeightsAreIgnored() {
        let onlyRate = SpeechProsody(rate: 0.5)
        let onlyPitch = SpeechProsody(pitchMultiplier: 1.2)
        let b = SpeechProsody.blend([(onlyRate, 1), (onlyPitch, 1), (.hypnagogicDreamer, 0)])
        XCTAssertEqual(b.rate, 0.5, "only the rate contributor sets rate")
        XCTAssertEqual(b.pitchMultiplier, 1.2, "only the pitch contributor sets pitch; zero-weight ignored")
        XCTAssertNil(b.volume, "no contributor specified volume ⇒ nil")
    }

    // MARK: - Loop coupling

    private actor ScriptListener: HypnagogicListening {
        nonisolated let isLive = false
        private var q: [String?]
        init(_ q: [String?]) { self.q = q }
        func requestAuthorization() async -> Bool { true }
        func listen(timeout: TimeInterval) async throws -> String? {
            if q.count > 1 { return q.removeFirst() }
            if let only = q.first { return only }
            try? await Task.sleep(nanoseconds: 5_000_000); return nil
        }
        func cancel() async {}
    }

    private actor TwoRoleGen: TextGenerating {
        nonisolated let isLive = false
        nonisolated let modelIdentifier = "g"
        let stab: String; let dream: String
        init(stab: String, dream: String) { self.stab = stab; self.dream = dream }
        func generate(prompt: String, maxTokens: Int, temperature: Double,
                      cancellationID: UUID) async throws -> String {
            temperature >= 0.9 ? dream : stab
        }
    }

    private struct MapEmbedder: SentenceEmbedder {
        let modelID = "m"; let dimension = 2; let version = "1"
        let table: [String: [Float]]
        func encode(_ texts: [String]) async throws -> [Embedding] {
            texts.map { t in
                let v = table[t] ?? [0, 0]
                let n = sqrtf(v.reduce(0) { $0 + $1 * $1 })
                return Embedding(values: n > 0 ? v.map { $0 / n } : v,
                                 modelID: modelID, dimension: dimension, version: version, seed: 0)
            }
        }
    }

    private actor ProsodySpeaker: SpeechSynthesizing {
        nonisolated let isLive = false
        nonisolated let voiceIdentifier = "p"
        private(set) var spoken: [String] = []
        private(set) var prosodies: [SpeechProsody] = []
        func speak(_ text: String) async throws { spoken.append(text); prosodies.append(SpeechProsody()) }
        func speak(_ text: String, prosody: SpeechProsody) async throws {
            spoken.append(text); prosodies.append(prosody)
        }
        func stopSpeaking() async {}
    }

    private func poll(timeout: TimeInterval = 2.0, _ p: @Sendable () async -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline { if await p() { return }; try? await Task.sleep(nanoseconds: 5_000_000) }
    }

    func testDreamerDominatedTurnIsVoicedWithDreamierProsody() async {
        // Dreamer candidate matches heard ⇒ higher potential ⇒ wins and dominates
        // the probability mass, so the blended voice leans toward the dreamer.
        let embedder = MapEmbedder(table: ["h": [0, 1], "stabWord": [1, 0], "dreamWord": [0, 1]])
        let speaker = ProsodySpeaker()
        let loop = HypnagogicDialecticLoop(
            listener: ScriptListener(["h"]),
            generator: TwoRoleGen(stab: "stabWord", dream: "dreamWord"),
            speaker: speaker, embedder: embedder, random: { 0.5 },
            config: .init(listenTimeout: 0.01, interTurnDelayNanos: 1_000)
        )
        await loop.start()
        await poll { await speaker.spoken.contains("dreamWord") }
        let prosody = await speaker.prosodies.first
        // Midpoint pitch between the two voices is (0.8+0.98)/2 = 0.89; a
        // dreamer-dominated blend must sit above it, near the dreamer's 0.98.
        XCTAssertNotNil(prosody?.pitchMultiplier)
        XCTAssertGreaterThan(prosody?.pitchMultiplier ?? 0, 0.89,
                             "a dreamer-dominated turn is voiced with dreamer-leaning pitch")
        await loop.stop()
    }
}
