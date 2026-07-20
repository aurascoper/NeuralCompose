import XCTest
import Foundation
@testable import BCICore

/// Milestone 6 (BCICore side) — the opt-in turn record and its projection.
final class DialecticalTelemetryTests: XCTestCase {

    private func emb(_ v: [Float]) -> Embedding {
        let n = sqrtf(v.reduce(0) { $0 + $1 * $1 })
        return Embedding(values: n > 0 ? v.map { $0 / n } : v,
                         modelID: "t", dimension: v.count, version: "1", seed: 0)
    }

    private func scored(_ role: String, potential: Float) -> ScoredCandidate {
        ScoredCandidate(
            candidate: DialecticalCandidate(text: "\(role)-text", embedding: emb([1, 0]), roleID: role),
            energy: .init(coherence: 0.7, resonance: 0.5, novelty: 0.3),
            potential: potential, roleFulfillment: 0.6
        )
    }

    private func competition(outcome: DialecticalOutcome) -> DialecticalCompetition {
        DialecticalCompetition(
            index: 4, heard: "the tide",
            scored: [scored("coherence-seeking", potential: 1.2),
                     scored("displacement-seeking", potential: 0.9)],
            tension: 0.5, margin: 0.3, selectionTemperature: 0.33,
            outcome: outcome, glossScalar: 0.5
        )
    }

    func testEventProjectsSpokeOutcomeAndCandidates() {
        let winner = DialecticalCandidate(text: "the tide turns", embedding: emb([1, 0]),
                                          roleID: "displacement-seeking")
        let event = DialecticalTurnEvent(competition(outcome: .spoke(winner)))
        XCTAssertEqual(event.index, 4)
        XCTAssertEqual(event.outcome, "spoke:displacement-seeking")
        XCTAssertEqual(event.spokenText, "the tide turns")
        XCTAssertEqual(event.candidates.count, 2, "both competitors are recorded, not just the winner")
        XCTAssertEqual(event.candidates.first?.roleID, "coherence-seeking")
    }

    func testEventProjectsSilentOutcome() {
        let event = DialecticalTurnEvent(competition(outcome: .silent))
        XCTAssertEqual(event.outcome, "silent")
        XCTAssertNil(event.spokenText, "a silent turn voiced nothing")
    }

    func testEventIsCodableRoundTrips() throws {
        let winner = DialecticalCandidate(text: "x", embedding: emb([1, 0]), roleID: "synthesis")
        let event = DialecticalTurnEvent(competition(outcome: .synthesized(winner)))
        let data = try JSONEncoder().encode(event)
        let back = try JSONDecoder().decode(DialecticalTurnEvent.self, from: data)
        XCTAssertEqual(back, event)
        XCTAssertEqual(back.outcome, "synthesized:synthesis")
    }

    // MARK: - Loop emits records

    private actor SpyTurnLogger: DialecticalTurnLogging {
        private(set) var events: [DialecticalTurnEvent] = []
        func log(_ event: DialecticalTurnEvent) async { events.append(event) }
    }
    private actor ScriptListener: HypnagogicListening {
        nonisolated let isLive = false
        private var q: [String?]
        init(_ q: [String?]) { self.q = q }
        func requestAuthorization() async -> Bool { true }
        func listen(timeout: TimeInterval) async throws -> String? {
            q.count > 1 ? q.removeFirst() : (q.first ?? nil)   // repeat the last value
        }
        func cancel() async {}
    }
    private actor Gen: TextGenerating {
        nonisolated let isLive = false
        nonisolated let modelIdentifier = "g"
        func generate(prompt: String, maxTokens: Int, temperature: Double,
                      cancellationID: UUID) async throws -> String {
            temperature >= 0.9 ? "dreamWord" : "stabWord"
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
    private actor Speaker: SpeechSynthesizing {
        nonisolated let isLive = false
        nonisolated let voiceIdentifier = "s"
        func speak(_ text: String) async throws {}
        func speak(_ text: String, prosody: SpeechProsody) async throws {}
        func stopSpeaking() async {}
    }

    func testLoopLogsEachTurnWhenAConcreteLoggerIsInjected() async {
        let logger = SpyTurnLogger()
        let loop = HypnagogicDialecticLoop(
            listener: ScriptListener(["hear"]),
            generator: Gen(),
            speaker: Speaker(),
            embedder: MapEmbedder(table: ["hear": [0, 1], "stabWord": [1, 0], "dreamWord": [0.9, 0.1]]),
            random: { 0.5 }, turnLogger: logger,
            config: .init(listenTimeout: 0.01, interTurnDelayNanos: 1_000)
        )
        await loop.start()
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline, await logger.events.isEmpty {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        let events = await logger.events
        XCTAssertFalse(events.isEmpty, "each dialectical turn is recorded when a logger is injected")
        XCTAssertEqual(events.first?.candidates.count, 2, "the whole competition is captured")
        await loop.stop()
    }
}
