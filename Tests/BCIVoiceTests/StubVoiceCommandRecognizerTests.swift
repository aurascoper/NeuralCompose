import XCTest
@testable import BCICore
@testable import BCIVoice

final class StubVoiceCommandRecognizerTests: XCTestCase {

    func testStubIsNotLiveAndHasStableEngineIdentifier() {
        let recognizer = StubVoiceCommandRecognizer()
        XCTAssertFalse(recognizer.isLive)
        XCTAssertEqual(recognizer.engineIdentifier, "stub-cmd")
    }

    func testStubNeverAuthorizes() async {
        let recognizer = StubVoiceCommandRecognizer()
        let granted = await recognizer.requestAuthorization()
        XCTAssertFalse(granted)
    }

    func testStubStartCommandAlwaysThrows() async {
        let recognizer = StubVoiceCommandRecognizer()
        do {
            try await recognizer.startCommand()
            XCTFail("stub recognizer should never successfully start command")
        } catch {
            XCTAssertTrue(error is BCIError, "expected BCIError, got \(error)")
        }
    }

    func testStubStopCommandReturnsEmptyTranscript() async throws {
        let recognizer = StubVoiceCommandRecognizer()
        let transcript = try await recognizer.stopCommand()
        XCTAssertEqual(transcript, "")
    }

    func testStubCancelCommandIsSafeWhenNotRecording() async {
        let recognizer = StubVoiceCommandRecognizer()
        await recognizer.cancelCommand() // must not throw
    }

    func testStubRecognizeLastTranscriptRejectsAsEmpty() async {
        let recognizer = StubVoiceCommandRecognizer()
        let (command, result) = await recognizer.recognizeLastTranscript()
        XCTAssertNil(command)
        XCTAssertEqual(result.rejectionReason, .emptyTranscript)
        XCTAssertEqual(result.transcript, "")
        XCTAssertEqual(result.normalized, "")
        XCTAssertEqual(result.confidence, 0.0)
    }
}
