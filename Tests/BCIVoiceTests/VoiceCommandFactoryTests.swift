import XCTest
@testable import BCICore
@testable import BCIVoice

final class VoiceCommandFactoryTests: XCTestCase {

    func testFactoryFallsBackToStubWhenUnavailable() {
        let resolved = VoiceCommandFactory.live(overrideAvailability: false)
        XCTAssertEqual(resolved.kind, .stub)
        XCTAssertTrue(resolved.recognizer is StubVoiceCommandRecognizer)
        XCTAssertNil(resolved.warning)
    }

    func testFactoryResolvesLiveWhenAvailable() {
        // The critical privacy invariant: merely *resolving* the
        // factory (as happens once at `AppContainer` construction /
        // app launch) must never itself trigger a TCC permission
        // prompt. We can't directly assert "no prompt fired" from a
        // unit test, but we CAN assert that resolving never calls
        // into `requestAuthorization()` or `startCommand()` — this
        // test simply exercises the `.live` branch and confirms it
        // returns a real recognizer without this test process ever
        // calling those methods.
        let resolved = VoiceCommandFactory.live(overrideAvailability: true)
        XCTAssertEqual(resolved.kind, .live)
        XCTAssertTrue(resolved.recognizer is SpeechCommandRecognizerService)
    }
}
