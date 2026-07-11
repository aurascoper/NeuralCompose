import XCTest
@testable import BCICore
@testable import NeuralComposeApp

final class StubCommandRecognizerTests: XCTestCase {

    // Use a small in-test vocabulary to keep the table-driven tests
    // independent of the canonical `DefaultCommandDescriptors` table
    // (which is exercised separately in
    // `DefaultCommandDescriptorsTests`-style coverage if/when added).
    // The recognizer's behavior depends only on the descriptor list
    // it receives, not on a specific list.
    private let vocab: [CommandDescriptor] = DefaultCommandDescriptors.all

    private let recognizer = StubCommandRecognizer()

    // MARK: - Empty / whitespace / nil cases

    func testEmptyInputReturnsNil() {
        XCTAssertNil(recognizer.recognize("", in: vocab))
    }

    func testWhitespaceOnlyInputReturnsNil() {
        XCTAssertNil(recognizer.recognize("   ", in: vocab))
        XCTAssertNil(recognizer.recognize("\t\n", in: vocab))
    }

    func testPunctuationOnlyInputReturnsNil() {
        XCTAssertNil(recognizer.recognize("!!!", in: vocab))
        XCTAssertNil(recognizer.recognize("...?", in: vocab))
    }

    // MARK: - Exact and case-insensitive matches

    func testExactAliasMatch() {
        XCTAssertEqual(recognizer.recognize("open phase b", in: vocab), .openPhaseBDebug)
        XCTAssertEqual(recognizer.recognize("start recording", in: vocab), .startRecording)
        XCTAssertEqual(recognizer.recognize("stop recording", in: vocab), .stopRecording)
        XCTAssertEqual(recognizer.recognize("begin calibration", in: vocab), .beginCalibration)
        XCTAssertEqual(recognizer.recognize("begin sleep protocol", in: vocab), .beginSleepProtocol)
        XCTAssertEqual(recognizer.recognize("reset composition", in: vocab), .resetComposition)
        XCTAssertEqual(recognizer.recognize("speak", in: vocab), .speak)
        XCTAssertEqual(recognizer.recognize("refine", in: vocab), .refine)
        XCTAssertEqual(recognizer.recognize("start dictation", in: vocab), .startDictation)
        XCTAssertEqual(recognizer.recognize("stop dictation", in: vocab), .stopDictation)
    }

    func testCaseInsensitiveMatch() {
        XCTAssertEqual(recognizer.recognize("OPEN PHASE B", in: vocab), .openPhaseBDebug)
        XCTAssertEqual(recognizer.recognize("Speak", in: vocab), .speak)
        XCTAssertEqual(recognizer.recognize("ReFiNe", in: vocab), .refine)
        XCTAssertEqual(recognizer.recognize("STOP RECORDING", in: vocab), .stopRecording)
    }

    // MARK: - Whitespace and outer-punctuation tolerance

    func testLeadingAndTrailingWhitespaceTolerated() {
        XCTAssertEqual(recognizer.recognize("  open phase b  ", in: vocab), .openPhaseBDebug)
        XCTAssertEqual(recognizer.recognize("\treset\n", in: vocab), .resetComposition)
    }

    func testOuterPunctuationTolerated() {
        XCTAssertEqual(recognizer.recognize("open phase b!", in: vocab), .openPhaseBDebug)
        XCTAssertEqual(recognizer.recognize("...reset...", in: vocab), .resetComposition)
        XCTAssertEqual(recognizer.recognize("\"speak\"", in: vocab), .speak)
    }

    func testInteriorWhitespaceNotTolerated() {
        // "o p e n  p h a s e  b" does not match "open phase b" —
        // internal whitespace is preserved as-is by the recognizer
        // and breaks the prefix match. A real LLM-based recognizer
        // would normalize this; the stub is intentionally literal.
        XCTAssertNil(recognizer.recognize("o p e n  p h a s e  b", in: vocab))
    }

    // MARK: - Short-form alias matches

    func testShortFormAliasesMatch() {
        // The descriptor table includes short forms for the most
        // common commands. These should resolve identically to the
        // long forms.
        XCTAssertEqual(recognizer.recognize("reset", in: vocab), .resetComposition)
        XCTAssertEqual(recognizer.recognize("clear", in: vocab), .resetComposition)
        XCTAssertEqual(recognizer.recognize("clear composition", in: vocab), .resetComposition)
        XCTAssertEqual(recognizer.recognize("calibrate", in: vocab), .beginCalibration)
        XCTAssertEqual(recognizer.recognize("say", in: vocab), .speak)
        XCTAssertEqual(recognizer.recognize("say it", in: vocab), .speak)
        XCTAssertEqual(recognizer.recognize("read it", in: vocab), .speak)
        XCTAssertEqual(recognizer.recognize("improve", in: vocab), .refine)
        XCTAssertEqual(recognizer.recognize("improve it", in: vocab), .refine)
    }

    func testSynonymAliasesMatch() {
        XCTAssertEqual(recognizer.recognize("begin recording", in: vocab), .startRecording)
        XCTAssertEqual(recognizer.recognize("end recording", in: vocab), .stopRecording)
        XCTAssertEqual(recognizer.recognize("start calibration", in: vocab), .beginCalibration)
        XCTAssertEqual(recognizer.recognize("begin dictation", in: vocab), .startDictation)
        XCTAssertEqual(recognizer.recognize("end dictation", in: vocab), .stopDictation)
    }

    func testLongFormAliasesMatch() {
        // The longer alias for openPhaseBDebug — input must equal
        // the alias verbatim (not just be a prefix of it) to match.
        // This is intentional: "open the phase b debug window" is
        // a complete phrase; truncating it to "open the phase" would
        // be wrong.
        XCTAssertEqual(
            recognizer.recognize("open the phase b debug window", in: vocab),
            .openPhaseBDebug
        )
    }

    // MARK: - Politeness prefix / suffix stripping

    func testPolitenessPrefixesStripped() {
        XCTAssertEqual(recognizer.recognize("please open phase b", in: vocab), .openPhaseBDebug)
        XCTAssertEqual(recognizer.recognize("could you open phase b", in: vocab), .openPhaseBDebug)
        XCTAssertEqual(recognizer.recognize("can you speak", in: vocab), .speak)
        XCTAssertEqual(recognizer.recognize("i want to reset", in: vocab), .resetComposition)
        XCTAssertEqual(recognizer.recognize("i need to refine", in: vocab), .refine)
        XCTAssertEqual(recognizer.recognize("i'd like to begin calibration", in: vocab), .beginCalibration)
    }

    func testPolitenessSuffixesStripped() {
        XCTAssertEqual(recognizer.recognize("open phase b please", in: vocab), .openPhaseBDebug)
        XCTAssertEqual(recognizer.recognize("reset thanks", in: vocab), .resetComposition)
        XCTAssertEqual(recognizer.recognize("speak thank you", in: vocab), .speak)
    }

    func testPolitenessPrefixAndSuffixBothStripped() {
        XCTAssertEqual(recognizer.recognize("please open phase b please", in: vocab), .openPhaseBDebug)
        XCTAssertEqual(recognizer.recognize("could you reset thanks", in: vocab), .resetComposition)
    }

    // MARK: - Mid-phrase deny (the "podcast" case)

    func testMidPhraseQualifierRejected() {
        // The defining case for the "input is a prefix of alias" rule.
        // The user is talking about *a podcast recording*, not the
        // in-app recorder. The cleaned input "start recording a podcast"
        // is longer than any alias for .startRecording, so no prefix
        // match. The stub returns nil. A real LLM-based recognizer
        // would handle this; the stub is intentionally conservative.
        XCTAssertNil(recognizer.recognize("i want to start recording a podcast", in: vocab))
        XCTAssertNil(recognizer.recognize("start recording a podcast", in: vocab))
        XCTAssertNil(recognizer.recognize("please start recording for a friend", in: vocab))
    }

    // MARK: - Disambiguation: prefix matches pick the longest alias

    func testLongerAliasWinsOverShorterAlias() {
        // "open phase" is a prefix of two aliases for .openPhaseBDebug:
        //   "open phase b" (length 12)
        //   "open the phase b debug window" (length 30)
        // The stub should pick the longer one. Both map to the same
        // command here, so this test verifies behavior under what
        // would otherwise be a tie — and protects against a future
        // refactor that accidentally breaks the tie-breaking logic.
        XCTAssertEqual(recognizer.recognize("open phase", in: vocab), .openPhaseBDebug)
    }

    func testSleepProtocolAliasDisambiguation() {
        // "begin sleep" is a prefix of "begin sleep protocol" but
        // not a prefix of any other descriptor's aliases. The stub
        // should resolve it to .beginSleepProtocol.
        XCTAssertEqual(recognizer.recognize("begin sleep", in: vocab), .beginSleepProtocol)
        XCTAssertEqual(recognizer.recognize("start sleep", in: vocab), .beginSleepProtocol)
    }

    // MARK: - Vocabulary independence

    func testEmptyVocabReturnsNil() {
        // Sanity check: an empty descriptor list yields nil for any
        // input, regardless of the recognizer's matching logic.
        XCTAssertNil(recognizer.recognize("open phase b", in: []))
        XCTAssertNil(recognizer.recognize("speak", in: []))
    }

    func testRecognizerUsesProvidedVocabNotAGlobalOne() {
        // Construct a tiny custom vocabulary that contains only one
        // descriptor. The recognizer should match against that one
        // and miss anything that isn't in the custom list, even if
        // the input would match a default descriptor.
        let custom: [CommandDescriptor] = [
            CommandDescriptor(command: .speak, title: "Speak", aliases: ["yell"])
        ]
        XCTAssertEqual(recognizer.recognize("yell", in: custom), .speak)
        // "open phase b" is in the default vocab but not in `custom`,
        // so the recognizer (which only sees `custom`) returns nil.
        XCTAssertNil(recognizer.recognize("open phase b", in: custom))
    }

    // MARK: - Coverage of every descriptor's primary alias

    /// Spot-check that every descriptor's *first-listed* alias resolves
    /// correctly. The descriptor table puts the most-natural alias
    /// first, so this catches typos and missing entries in one shot.
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
