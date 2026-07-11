import XCTest
@testable import BCICore
@testable import BCIVoice

final class SpeechCommandRecognizerServiceTests: XCTestCase {

    // These tests don't exercise the real `SFSpeechRecognizer`
    // pipeline (which requires a microphone, locale support, and
    // user-granted TCC permissions — none of which are
    // appropriate for a unit test). They verify the shape of the
    // service: the constructor wires the parser closure and
    // vocabulary, and the recognizer reports the right `isLive`
    // / `engineIdentifier` for downstream consumers (privacy
    // banner, factory, tests).

    func testServiceIsLiveAndEngineIdentifierMatchesLocale() {
        let service = SpeechCommandRecognizerService(locale: Locale(identifier: "en-US"))
        XCTAssertTrue(service.isLive)
        XCTAssertEqual(service.engineIdentifier, "sfspeech-cmd-en-US")
    }

    func testServiceEngineIdentifierChangesWithLocale() {
        let service = SpeechCommandRecognizerService(locale: Locale(identifier: "fr-FR"))
        XCTAssertEqual(service.engineIdentifier, "sfspeech-cmd-fr-FR")
    }

    func testStopCommandReturnsEmptyWhenNotRecording() async throws {
        // The service treats `stopCommand()` as a no-op when not
        // recording (mirroring `PushToTalkSpeechRecognizerService`).
        // This is the property the UI relies on for the
        // press-and-release race: even if the user releases
        // before the recognizer reports active, stop returns
        // safely.
        let service = SpeechCommandRecognizerService()
        let transcript = try await service.stopCommand()
        XCTAssertEqual(transcript, "")
    }

    func testCancelCommandIsSafeWhenNotRecording() async {
        let service = SpeechCommandRecognizerService()
        await service.cancelCommand() // must not throw
    }

    func testRecognizeLastTranscriptWithoutBufferIsEmptyRejection() async {
        // The service doesn't buffer transcripts across the
        // stop->recognize boundary (the UI's wiring uses
        // `stopAndRecognize()` instead). Calling
        // `recognizeLastTranscript()` directly therefore returns
        // an empty-transcript rejection. This is a contract
        // assertion, not a behavior we'd expect in production.
        let service = SpeechCommandRecognizerService()
        let (command, result) = await service.recognizeLastTranscript()
        XCTAssertNil(command)
        XCTAssertEqual(result.rejectionReason, .emptyTranscript)
    }

    // MARK: - Parser closure contract

    func testStopAndRecognizeRunsTheProvidedParserClosure() async throws {
        // The constructor takes a parser closure (rather than
        // an `AppCommandRecognizing` instance) so the voice
        // module stays agnostic of the parser type. This test
        // pins that contract: the closure is invoked with the
        // final transcript and the configured vocabulary, and
        // the returned command is what the recognizer reports.
        let recorder = ParserCallRecorder()
        let vocabulary: [CommandDescriptor] = [
            CommandDescriptor(
                command: .speak,
                title: "Speak",
                aliases: ["speak", "say it"]
            )
        ]
        let service = SpeechCommandRecognizerService(
            locale: Locale(identifier: "en-US"),
            parser: { text, descriptors in
                recorder.record(text: text, descriptors: descriptors)
                return .speak
            },
            vocabulary: vocabulary
        )
        // We're not recording, so `stopCommand()` returns "" and
        // the parser is invoked with an empty transcript. This
        // proves the wiring without needing a real mic.
        let (command, result) = try await service.stopAndRecognize()
        XCTAssertEqual(command, .speak)
        XCTAssertEqual(result.command, .speak)
        XCTAssertEqual(result.transcript, "")
        XCTAssertEqual(result.normalized, "")
        XCTAssertEqual(result.confidence, 1.0)
        XCTAssertNil(result.rejectionReason)
        XCTAssertEqual(recorder.calls.count, 1)
        XCTAssertEqual(recorder.calls.first?.text, "")
        XCTAssertEqual(recorder.calls.first?.descriptors.count, vocabulary.count)
    }
}

/// Holds the captured parser-closure invocations for inspection
/// in `testStopAndRecognizeRunsTheProvidedParserClosure`. Lives
/// outside the test class so the captured `var` is a reference,
/// not a captured value (the @Sendable closure can't capture a
/// `var` by reference; a class instance sidesteps the diagnostic).
private final class ParserCallRecorder: @unchecked Sendable {
    struct Call: Sendable {
        let text: String
        let descriptors: [CommandDescriptor]
    }
    private let lock = NSLock()
    private var _calls: [Call] = []
    var calls: [Call] {
        lock.lock(); defer { lock.unlock() }
        return _calls
    }
    func record(text: String, descriptors: [CommandDescriptor]) {
        lock.lock(); defer { lock.unlock() }
        _calls.append(Call(text: text, descriptors: descriptors))
    }
}
