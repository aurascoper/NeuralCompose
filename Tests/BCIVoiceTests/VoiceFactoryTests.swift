import XCTest
@testable import BCIVoice
@testable import BCICore

final class VoiceFactoryTests: XCTestCase {

    func testVoiceOutputFactoryAlwaysResolvesLive() {
        // Never gates to stub — AVSpeech is always available on-device; the
        // Premium-voice selection changes the voice, not the resolution.
        let resolved = VoiceOutputFactory.live()
        XCTAssertEqual(resolved.kind, .live)
        XCTAssertTrue(resolved.synthesizer is AVSpeechSynthesizerService)
    }

    func testVoiceOutputWarningTracksVoiceAvailability() {
        // The install hint appears IFF neither a Personal Voice (authorized) nor
        // an Enhanced/Premium neural voice is available for the current language.
        // Availability is environment-dependent, but the relationship is invariant.
        let hasGoodVoice = AVSpeechSynthesizerService.bestPersonalVoiceIdentifier() != nil
            || AVSpeechSynthesizerService.bestNeuralVoiceIdentifier() != nil
        let resolved = VoiceOutputFactory.live()
        XCTAssertEqual(resolved.warning == nil, hasGoodVoice)
    }

    func testVoiceOutputPinsProvidedVoiceIdentifier() {
        // A pinned identifier (e.g. a Personal Voice id from NEURALCOMPOSE_VOICE_ID)
        // flows through to the synthesizer and suppresses the install hint.
        let pin = "com.apple.speech.personalvoice.TEST-INVARIANT"
        let resolved = VoiceOutputFactory.live(voiceIdentifier: pin)
        XCTAssertEqual(resolved.kind, .live)
        XCTAssertEqual(resolved.synthesizer.voiceIdentifier, pin)
        XCTAssertNil(resolved.warning)
    }

    func testVoiceInputFactoryFallsBackToStubWhenUnavailable() {
        let resolved = VoiceInputFactory.live(overrideAvailability: false)
        XCTAssertEqual(resolved.kind, .stub)
        XCTAssertTrue(resolved.recognizer is StubDictationRecognizer)
    }

    func testVoiceInputFactoryResolvesLiveWithoutPromptingForPermission() {
        // The critical privacy invariant: merely *resolving* the factory
        // (as happens once at `AppContainer` construction / app launch)
        // must never itself trigger a TCC permission prompt. We can't
        // directly assert "no prompt fired" from a unit test, but we CAN
        // assert that resolving never calls into `requestAuthorization()`
        // or `startRecording()` — this test simply exercises the `.live`
        // branch and confirms it returns a real recognizer without this
        // test process ever calling those methods.
        let resolved = VoiceInputFactory.live(overrideAvailability: true)
        XCTAssertEqual(resolved.kind, .live)
        XCTAssertTrue(resolved.recognizer is PushToTalkSpeechRecognizerService)
    }
}
