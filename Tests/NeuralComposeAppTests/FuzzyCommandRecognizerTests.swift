import XCTest
@testable import BCICore
@testable import NeuralComposeApp

final class FuzzyCommandRecognizerTests: XCTestCase {

    private let vocab: [CommandDescriptor] = DefaultCommandDescriptors.all
    private let recognizer = FuzzyCommandRecognizer()

    // MARK: - Acceptance table (the commit's own spec)

    func testStartRecordingAcceptsExactAlias() {
        XCTAssertEqual(recognizer.recognize("start recording", in: vocab), .startRecording)
    }

    func testBeginRecordingAcceptsSynonymAlias() {
        XCTAssertEqual(recognizer.recognize("begin recording", in: vocab), .startRecording)
    }

    func testPhaseBeeDebugResolvesViaLetterHomophoneAndFuzzyMatch() {
        // "bee" is the ASR spelling of the letter "b" in "Phase B" —
        // collapsed to "b" by CommandTextNormalizer, then fuzzy-matched
        // against the "open phase b debug" alias.
        XCTAssertEqual(recognizer.recognize("phase bee debug", in: vocab), .openPhaseBDebug)
    }

    func testPleaseStopRecordingStripsPolitenessThenMatches() {
        XCTAssertEqual(recognizer.recognize("please stop recording", in: vocab), .stopRecording)
    }

    func testOpenTheDebugThingIsRejectedAsUnrelated() {
        // Shares "open"/"debug" with openPhaseBDebug's aliases but not
        // enough to be the same phrase — deferred to a future
        // embedding-based layer, not this one.
        XCTAssertNil(recognizer.recognize("open the debug thing", in: vocab))
    }

    func testRecordAloneIsRejectedAsAmbiguous() {
        // "record" is equally close to "start recording" and "stop
        // recording"/"end recording" (the shared word "recording"),
        // with nothing in the utterance to say which one was meant.
        XCTAssertNil(recognizer.recognize("record", in: vocab))
    }

    // MARK: - Input-coverage guard (the "podcast" case, fuzzy edition)

    func testMidPhraseQualifierRejectedDespitePartialOverlap() {
        // "start recording" is a strong partial match inside this
        // sentence, but "a podcast" is unexplained leftover content —
        // the user is talking about a podcast recording, not the
        // in-app recorder. Mirrors `StubCommandRecognizer`'s prefix
        // rule for the same phrase (see that type's test suite).
        XCTAssertNil(recognizer.recognize("start recording a podcast", in: vocab))
        XCTAssertNil(recognizer.recognize("i want to start recording a podcast", in: vocab))
    }

    // MARK: - Empty / whitespace / punctuation / gibberish

    func testEmptyInputReturnsNil() {
        XCTAssertNil(recognizer.recognize("", in: vocab))
    }

    func testWhitespaceOnlyInputReturnsNil() {
        XCTAssertNil(recognizer.recognize("   ", in: vocab))
    }

    func testPunctuationOnlyInputReturnsNil() {
        XCTAssertNil(recognizer.recognize("!!!", in: vocab))
    }

    func testGibberishReturnsNil() {
        XCTAssertNil(recognizer.recognize("asdlkfjasldkfj qwooo", in: vocab))
    }

    // MARK: - Case-insensitivity and outer punctuation

    func testCaseInsensitiveMatch() {
        XCTAssertEqual(recognizer.recognize("START RECORDING", in: vocab), .startRecording)
        XCTAssertEqual(recognizer.recognize("Phase Bee Debug", in: vocab), .openPhaseBDebug)
    }

    func testOuterPunctuationTolerated() {
        XCTAssertEqual(recognizer.recognize("start recording!", in: vocab), .startRecording)
        XCTAssertEqual(recognizer.recognize("...reset...", in: vocab), .resetComposition)
    }

    // MARK: - Short-form and synonym aliases (parity with the stub)

    func testShortFormAliasesMatch() {
        XCTAssertEqual(recognizer.recognize("reset", in: vocab), .resetComposition)
        XCTAssertEqual(recognizer.recognize("calibrate", in: vocab), .beginCalibration)
        XCTAssertEqual(recognizer.recognize("speak", in: vocab), .speak)
    }

    func testDisambiguationBetweenSimilarCommands() {
        // "begin sleep" / "start sleep" are direct aliases of
        // .beginSleepProtocol and must not bleed into .beginCalibration
        // or .startRecording despite sharing the word "start"/"begin".
        XCTAssertEqual(recognizer.recognize("begin sleep", in: vocab), .beginSleepProtocol)
        XCTAssertEqual(recognizer.recognize("start sleep", in: vocab), .beginSleepProtocol)
    }

    func testStartAndStopCommandListeningResolveDistinctly() {
        XCTAssertEqual(recognizer.recognize("start command", in: vocab), .startCommand)
        XCTAssertEqual(recognizer.recognize("stop command listening", in: vocab), .stopCommand)
    }

    // MARK: - Vocabulary independence

    func testEmptyVocabReturnsNil() {
        XCTAssertNil(recognizer.recognize("open phase b", in: []))
    }

    func testRecognizerUsesProvidedVocabNotAGlobalOne() {
        let custom: [CommandDescriptor] = [
            CommandDescriptor(command: .speak, title: "Speak", aliases: ["yell"])
        ]
        XCTAssertEqual(recognizer.recognize("yell", in: custom), .speak)
        XCTAssertNil(recognizer.recognize("open phase b", in: custom))
    }

    // MARK: - Coverage of every descriptor's primary alias

    func testEveryDescriptorResolvesViaFirstAlias() {
        for descriptor in vocab {
            let firstAlias = descriptor.aliases.first ?? ""
            let result = recognizer.recognize(firstAlias, in: vocab)
            XCTAssertEqual(
                result, descriptor.command,
                "first alias \(firstAlias.debugDescription) for \(descriptor.command) should resolve to \(descriptor.command), got \(String(describing: result))"
            )
        }
    }
}
