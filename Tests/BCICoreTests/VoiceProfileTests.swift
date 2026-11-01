import XCTest
@testable import BCICore

/// Stage 4 — persisted voice preferences. These pin that a partial/absent profile
/// degrades gracefully (every key optional → env-var/auto-select fallback) and
/// that prosody round-trips, so a hand- or script-written voice-profile.json can't
/// silently fail to load.
final class VoiceProfileTests: XCTestCase {

    func testDecodesPartialJSON() throws {
        let json = Data("""
        { "usePersonalVoice": true,
          "voiceIdentifier": "com.apple.speech.personalvoice.ABC",
          "register": "schopenhauer" }
        """.utf8)
        let p = try JSONDecoder().decode(VoiceProfile.self, from: json)
        XCTAssertEqual(p.usePersonalVoice, true)
        XCTAssertEqual(p.voiceIdentifier, "com.apple.speech.personalvoice.ABC")
        XCTAssertEqual(p.register, "schopenhauer")
        XCTAssertNil(p.prosody, "unset keys stay nil so the env-var/auto-select fallback wins")
    }

    func testEmptyObjectDecodesToAllNil() throws {
        let p = try JSONDecoder().decode(VoiceProfile.self, from: Data("{}".utf8))
        XCTAssertNil(p.usePersonalVoice)
        XCTAssertNil(p.voiceIdentifier)
        XCTAssertNil(p.prosody)
        XCTAssertNil(p.register)
        XCTAssertNil(p.recognitionVocabulary)
        XCTAssertNil(p.endOfUtteranceSilence)
    }

    func testRecognitionSettingsDecodeAlongsideTheExistingKeys() throws {
        // The shape of Hunter's live profile plus the two hand-edited keys.
        let json = Data("""
        {"usePersonalVoice": true,
         "voiceIdentifier": "com.apple.speech.personalvoice.5EF4C909",
         "recognitionVocabulary": ["Oklo", "samarium"],
         "endOfUtteranceSilence": 2.5}
        """.utf8)
        let p = try JSONDecoder().decode(VoiceProfile.self, from: json)
        XCTAssertEqual(p.usePersonalVoice, true)
        XCTAssertEqual(p.recognitionVocabulary, ["Oklo", "samarium"])
        XCTAssertEqual(p.endOfUtteranceSilence, 2.5)
    }

    func testRoundTripsWithProsody() throws {
        let p = VoiceProfile(
            usePersonalVoice: true,
            voiceIdentifier: "com.apple.speech.personalvoice.5EF4C909",
            prosody: SpeechProsody(rate: 0.48, pitchMultiplier: 0.98, volume: 0.95, preUtteranceDelay: 0.12),
            register: "zen-classical")
        let back = try JSONDecoder().decode(VoiceProfile.self, from: JSONEncoder().encode(p))
        XCTAssertEqual(p, back)
        XCTAssertEqual(back.prosody?.rate, 0.48)
        XCTAssertEqual(back.prosody?.pitchMultiplier, 0.98)
    }

    func testDefaultURLIsUnderDocumentsNeuralCompose() throws {
        let url = try XCTUnwrap(VoiceProfile.defaultURL())
        XCTAssertTrue(url.path.hasSuffix("Documents/NeuralCompose/voice-profile.json"), url.path)
    }

    func testEffectiveRecognitionVocabularyIncludesColdRunDefaultsAndDeduplicates() {
        let coldVocab = VoiceProfile.effectiveRecognitionVocabulary(for: nil)
        XCTAssertTrue(coldVocab.contains("Hunter"))
        XCTAssertTrue(coldVocab.contains("aurascoper"))
        XCTAssertTrue(coldVocab.contains("GitHub"))
        XCTAssertTrue(coldVocab.contains("Antigravity"))
        XCTAssertTrue(coldVocab.contains("NeuralCompose"))
        XCTAssertTrue(coldVocab.contains("automorphism"))
        XCTAssertTrue(coldVocab.contains("Cantor space"))
        XCTAssertTrue(coldVocab.contains("eigen-behaviors"))
        XCTAssertTrue(coldVocab.contains("Yang-Mills"))
        XCTAssertTrue(coldVocab.contains("Exponential Time Hypothesis"))
        XCTAssertTrue(coldVocab.contains("equifinality"))
        XCTAssertTrue(coldVocab.contains("von Bertalanffy"))
        XCTAssertTrue(coldVocab.contains("genomes"))
        XCTAssertTrue(coldVocab.contains("renormalization group"))
        XCTAssertTrue(coldVocab.contains("Brett"))
        XCTAssertTrue(coldVocab.contains("Qwen"))

        let custom = VoiceProfile(recognitionVocabulary: ["CustomTerm", "aurascoper"])
        let merged = VoiceProfile.effectiveRecognitionVocabulary(for: custom)
        XCTAssertEqual(merged.first, "CustomTerm")
        XCTAssertEqual(merged.filter { $0.lowercased() == "aurascoper" }.count, 1)
    }
}
