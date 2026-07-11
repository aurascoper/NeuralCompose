import XCTest
@testable import BCIVoice
@testable import BCICore

final class StubVoiceTests: XCTestCase {

    func testStubSpeechSynthesizerIsNotLiveAndSpeaksWithoutThrowing() async throws {
        let synth = StubSpeechSynthesizer()
        XCTAssertFalse(synth.isLive)
        try await synth.speak("hello world")
        await synth.stopSpeaking() // safe to call even when idle
    }

    func testStubDictationRecognizerNeverAuthorizesOrTouchesHardware() async {
        let recognizer = StubDictationRecognizer()
        XCTAssertFalse(recognizer.isLive)
        let granted = await recognizer.requestAuthorization()
        XCTAssertFalse(granted)

        do {
            try await recognizer.startRecording()
            XCTFail("stub recognizer should never successfully start recording")
        } catch {
            XCTAssertTrue(error is BCIError)
        }

        let transcript = try? await recognizer.stopRecording()
        XCTAssertEqual(transcript, "")
        await recognizer.cancelRecording() // safe to call even when not recording
    }
}
