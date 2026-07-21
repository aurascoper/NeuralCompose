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
}
