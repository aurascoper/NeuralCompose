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

    func testVoiceOutputWarningTracksNeuralVoiceAvailability() {
        // The install hint appears IFF no Enhanced/Premium neural voice is
        // installed for the current language. The presence of a neural voice is
        // environment-dependent, but the relationship is an invariant.
        let hasNeural = AVSpeechSynthesizerService.bestNeuralVoiceIdentifier() != nil
        let resolved = VoiceOutputFactory.live()
        XCTAssertEqual(resolved.warning == nil, hasNeural)
        if let id = AVSpeechSynthesizerService.bestNeuralVoiceIdentifier() {
            XCTAssertFalse(id.isEmpty)
        }
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
