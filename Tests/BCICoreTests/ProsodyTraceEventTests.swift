import XCTest
@testable import BCICore

final class ProsodyTraceEventTests: XCTestCase {

    func testRequestedProsodyMapsToFeatureVector() {
        let prosody = SpeechProsody(
            rate: 0.5,
            pitchMultiplier: 1.08,
            volume: 0.75,
            preUtteranceDelay: 0.2
        )

        let vector = ProsodyFeatureVector(
            requested: prosody,
            pauseAfter: 0.15,
            duration: 2.0,
            syllableCount: 5,
            emphasis: 0.4,
            hesitation: 0.1,
            cadenceClass: "reflective"
        )

        XCTAssertEqual(vector.speechRate ?? -1, 0.5, accuracy: 0.0001)
        XCTAssertEqual(vector.pauseBefore ?? -1, 0.2, accuracy: 0.0001)
        XCTAssertEqual(vector.pauseAfter ?? -1, 0.15, accuracy: 0.0001)
        XCTAssertEqual(vector.meanPitch ?? -1, 1.08, accuracy: 0.0001)
        XCTAssertEqual(vector.energy ?? -1, 0.75, accuracy: 0.0001)
        XCTAssertEqual(vector.duration ?? -1, 2.0, accuracy: 0.0001)
        XCTAssertEqual(vector.syllablesPerSecond ?? -1, 2.5, accuracy: 0.0001)
        XCTAssertEqual(vector.cadenceClass, "reflective")
    }

    func testTraceEncodingUsesStableScienceFieldNames() throws {
        let event = ProsodyTraceEvent(
            index: 7,
            sourceKind: "spoken-generation",
            utteranceText: "That's interesting.",
            embeddingModelID: "stub-hash-v1",
            embeddingVersion: "1",
            dialogueState: [
                "coherence": 0.72,
                "continuation_pressure": 0.31,
            ],
            requested: ProsodyFeatureVector(
                requested: .wakingCoherent,
                duration: 1.25,
                syllableCount: 4,
                cadenceClass: "curious"
            ),
            measured: nil,
            voiceIdentifier: "system-default",
            synthesizerIdentifier: "avspeech"
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(event)
        let json = String(decoding: data, as: UTF8.self)

        XCTAssertTrue(json.contains("\"schema_version\":\"prosody-trace-v0\""))
        XCTAssertTrue(json.contains("\"utterance_text\":\"That's interesting.\""))
        XCTAssertTrue(json.contains("\"embedding_model_id\":\"stub-hash-v1\""))
        XCTAssertTrue(json.contains("\"dialogue_state\""))
        XCTAssertTrue(json.contains("\"speech_rate\""))
        XCTAssertTrue(json.contains("\"pause_before\""))
        XCTAssertTrue(json.contains("\"syllables_per_second\""))
        XCTAssertFalse(json.contains("\"speechRate\""))
        XCTAssertFalse(json.contains("\"values\""))
    }

    func testMeasuredFeatureEncodingMatchesRustPhase0Contract() throws {
        let event = ProsodyTraceEvent(
            index: 2,
            sourceKind: "rust-prosody-features",
            utteranceText: "measured phrase",
            measured: ProsodyFeatureVector(
                speechRate: 4.0,
                pauseBefore: 0.1,
                pauseAfter: 0.2,
                meanPitch: 180.0,
                pitchVariance: 12.0,
                energy: 0.7,
                duration: 1.5,
                voicedDuration: 1.1,
                syllablesPerSecond: 4.0,
                articulationRate: 5.45,
                pauseDensity: 0.25,
                rms: 0.33,
                zeroCrossingRate: 220.0,
                spectralCentroid: 910.0,
                pitchConfidence: 0.82,
                voicingProbability: 0.75,
                energyEntropy: 0.61
            )
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(event)
        let json = String(decoding: data, as: UTF8.self)

        for field in [
            "articulation_rate",
            "energy_entropy",
            "pause_density",
            "pitch_confidence",
            "spectral_centroid",
            "voiced_duration",
            "voicing_probability",
            "zero_crossing_rate",
        ] {
            XCTAssertTrue(json.contains("\"\(field)\""), "missing \(field) in \(json)")
        }
        XCTAssertFalse(json.contains("articulationRate"))
        XCTAssertFalse(json.contains("energyEntropy"))
    }

    func testProsodyPredictingDoesNotRequireSpeechBackend() async throws {
        struct TensionProsodyModel: ProsodyPredicting {
            let modelID = "test-tension-prosody"
            let version = "1"

            func predictProsody(for request: ProsodyPredictionRequest) async throws -> SpeechProsody {
                let tension = request.dialogueState["tension"] ?? 0
                return SpeechProsody(
                    rate: tension > 0.5 ? 0.42 : 0.52,
                    pitchMultiplier: request.embedding == nil ? 1.0 : 1.04,
                    volume: 0.8,
                    preUtteranceDelay: request.history.isEmpty ? 0.1 : 0.0
                )
            }
        }

        let request = ProsodyPredictionRequest(
            text: "Maybe this should slow down.",
            embedding: Embedding(
                values: [1.0, 0.0],
                modelID: "stub-hash-v1",
                dimension: 2,
                version: "1",
                seed: 0
            ),
            dialogueState: ["tension": 0.8],
            history: []
        )

        let prosody = try await TensionProsodyModel().predictProsody(for: request)

        XCTAssertEqual(prosody.rate ?? -1, 0.42, accuracy: 0.0001)
        XCTAssertEqual(prosody.pitchMultiplier ?? -1, 1.04, accuracy: 0.0001)
        XCTAssertEqual(prosody.preUtteranceDelay ?? -1, 0.1, accuracy: 0.0001)
    }
}
