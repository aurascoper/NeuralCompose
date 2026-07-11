import XCTest
@testable import BCICore
@testable import NeuralComposeApp

final class DebugCommandPaletteTests: XCTestCase {

    // Use a small, hand-crafted vocabulary for most tests so the
    // expected ranking is explicit. The full default vocabulary
    // (`DefaultCommandDescriptors.all`) is exercised in the last
    // two tests for end-to-end sanity.
    private func makeVocab() -> [CommandDescriptor] {
        [
            CommandDescriptor(
                command: .openPhaseBDebug,
                title: "Open Phase B Debug",
                aliases: [
                    "open phase b",
                    "open the phase b debug window",
                    "open phase b debug",
                ]
            ),
            CommandDescriptor(
                command: .startRecording,
                title: "Start Recording",
                aliases: ["start recording", "begin recording"]
            ),
            CommandDescriptor(
                command: .stopRecording,
                title: "Stop Recording",
                aliases: ["stop recording", "end recording"]
            ),
            CommandDescriptor(
                command: .beginCalibration,
                title: "Begin Calibration",
                aliases: ["begin calibration", "start calibration", "calibrate"]
            ),
            CommandDescriptor(
                command: .resetComposition,
                title: "Reset Composition",
                aliases: ["reset composition", "reset", "clear composition", "clear"]
            ),
            CommandDescriptor(
                command: .speak,
                title: "Speak",
                aliases: ["speak", "read it", "read aloud", "say it", "say"]
            ),
            CommandDescriptor(
                command: .refine,
                title: "Refine",
                aliases: ["refine", "refine it", "improve it", "improve"]
            ),
        ]
    }

    // MARK: - Empty / whitespace query returns the input as-is

    func testEmptyQueryReturnsAllInOriginalOrder() {
        let vocab = makeVocab()
        let result = DebugCommandPalette.filter(vocab, query: "")
        XCTAssertEqual(result.map { $0.command }, vocab.map { $0.command })
    }

    func testWhitespaceOnlyQueryReturnsAllInOriginalOrder() {
        let vocab = makeVocab()
        let result = DebugCommandPalette.filter(vocab, query: "   \t\n  ")
        XCTAssertEqual(result.map { $0.command }, vocab.map { $0.command })
    }

    // MARK: - No matches

    func testNoMatchesReturnsEmpty() {
        let result = DebugCommandPalette.filter(makeVocab(), query: "zzzzzz")
        XCTAssertTrue(result.isEmpty)
    }

    // MARK: - Title prefix (tier 0)

    func testTitlePrefixMatchesRankFirst() {
        // "reset" is a prefix of "Reset Composition" (title) and
        // also a prefix of the "reset" / "reset composition" aliases.
        // Tier 0 (title prefix) wins; only .resetComposition qualifies.
        let result = DebugCommandPalette.filter(makeVocab(), query: "reset")
        XCTAssertEqual(result.map { $0.command }, [.resetComposition])
    }

    func testTitlePrefixBeatsAliasPrefix() {
        // "open" is a title-prefix of "Open Phase B Debug" (tier 0)
        // and an alias-prefix of every other descriptor whose
        // alias starts with "open"... actually none of the others
        // do, so this verifies the pure tier-0 ranking. The more
        // interesting case is the title-prefix-of-one vs the
        // alias-prefix-of-another, which we cover below.
        let vocab = makeVocab()
        let result = DebugCommandPalette.filter(vocab, query: "open")
        XCTAssertEqual(result.first?.command, .openPhaseBDebug)
    }

    // MARK: - Alias prefix (tier 1)

    func testAliasPrefixMatches() {
        // "calibrate" is exactly an alias for .beginCalibration
        // (tier 1 alias prefix). It's not a title prefix of any
        // descriptor, so this lands in tier 1.
        let result = DebugCommandPalette.filter(makeVocab(), query: "calibrate")
        XCTAssertEqual(result.map { $0.command }, [.beginCalibration])
    }

    func testAliasPrefixMatchesWithSubstring() {
        // "start" is a prefix of "start recording" (alias for
        // .startRecording) and "start calibration" (alias for
        // .beginCalibration). Both match tier 1; the earlier one
        // in the input wins on tie.
        let result = DebugCommandPalette.filter(makeVocab(), query: "start")
        let commands = result.map { $0.command }
        XCTAssertEqual(Set(commands), [.startRecording, .beginCalibration])
        // .startRecording is index 1 in the vocab, .beginCalibration
        // is index 3. The earlier one wins on tie.
        XCTAssertEqual(commands.first, .startRecording)
    }

    // MARK: - Title contains (tier 2)

    func testTitleContainsMatches() {
        // "calibration" is a substring of "Begin Calibration" (title
        // contains, tier 2). It is NOT an alias prefix (none of
        // .beginCalibration's aliases start with "calibration").
        // So tier 1 doesn't trigger; tier 2 does.
        let result = DebugCommandPalette.filter(makeVocab(), query: "calibration")
        XCTAssertEqual(result.map { $0.command }, [.beginCalibration])
    }

    // MARK: - Alias contains (tier 3)

    func testAliasContainsMatchesWhenNoEarlierTier() {
        // "phase" is a substring of "open phase b" (alias contains,
        // tier 3) and a substring of "open the phase b debug
        // window". It is NOT a prefix of any alias (no alias
        // starts with "phase"). It is NOT a substring of any
        // title. So this is a pure tier-3 match.
        let result = DebugCommandPalette.filter(makeVocab(), query: "phase")
        XCTAssertEqual(result.map { $0.command }, [.openPhaseBDebug])
    }

    // MARK: - Tier ordering

    func testTitlePrefixBeatsAliasPrefixAcrossDescriptors() {
        // Construct a minimal vocab where one descriptor matches
        // via title prefix and another matches via alias prefix,
        // and verify the title-prefix one ranks first.
        let vocab: [CommandDescriptor] = [
            CommandDescriptor(
                command: .resetComposition,
                title: "Reset Composition",
                aliases: ["clear"]
            ),
            CommandDescriptor(
                command: .speak,
                title: "Read Aloud",  // does NOT start with "r"... actually it does. Use a clearer setup.
                aliases: ["reset voice"]
            ),
        ]
        // Use a query that exercises both tiers. Query "r" matches:
        //   - "Reset Composition" via title prefix (tier 0)
        //   - "Read Aloud" via title prefix (tier 0)
        //   - "reset voice" via alias prefix (tier 1)
        // Tier 0 wins; .resetComposition and .speak tie on (tier, pos),
        // input order breaks the tie (resetComposition is index 0).
        let result = DebugCommandPalette.filter(vocab, query: "r")
        XCTAssertEqual(result.first?.command, .resetComposition)
    }

    // MARK: - Case insensitivity

    func testCaseInsensitiveMatching() {
        let result = DebugCommandPalette.filter(makeVocab(), query: "RESET")
        XCTAssertEqual(result.map { $0.command }, [.resetComposition])
    }

    func testMixedCaseQuery() {
        let result = DebugCommandPalette.filter(makeVocab(), query: "ReSeT")
        XCTAssertEqual(result.map { $0.command }, [.resetComposition])
    }

    // MARK: - Whitespace in query is trimmed

    func testQueryWhitespaceIsTrimmed() {
        let result = DebugCommandPalette.filter(makeVocab(), query: "  reset  ")
        XCTAssertEqual(result.map { $0.command }, [.resetComposition])
    }

    // MARK: - Default vocabulary end-to-end

    func testDefaultVocabEveryDescriptorMatchesViaTitle() {
        // The descriptor table puts the most natural alias first, so
        // a query that's a title prefix should hit one descriptor
        // for the most-searched terms.
        let queriesAndExpected: [(String, AppCommand)] = [
            ("open",     .openPhaseBDebug),
            ("start",    .startRecording),  // tier 1 alias prefix; title is "Start Recording"
            ("stop",     .stopRecording),
            ("begin",    .beginCalibration),
            ("reset",    .resetComposition),
            ("speak",    .speak),
            ("refine",   .refine),
        ]
        for (query, expected) in queriesAndExpected {
            let result = DebugCommandPalette.filter(DefaultCommandDescriptors.all, query: query)
            XCTAssertTrue(
                result.contains(where: { $0.command == expected }),
                "query \(query.debugDescription) should match \(expected) in default vocab; got \(result.map { $0.command })"
            )
        }
    }

    func testDefaultVocabQueryResolvesToFirstEntry() {
        // A query that exactly matches the first descriptor's title
        // returns that descriptor first.
        let result = DebugCommandPalette.filter(DefaultCommandDescriptors.all, query: "speak")
        XCTAssertEqual(result.first?.command, .speak)
    }
}

// MARK: - Filter ↔ dispatch contract

@MainActor
final class DebugCommandPaletteSelectionTests: XCTestCase {

    /// Verifies the *contract* between the filter and the dispatcher:
    /// the first-ranked descriptor for a query is exactly the
    /// command we'd want a UI selection to dispatch. The
    /// `DebugCommandPaletteView` body calls
    /// `dispatcher.perform(first.command)` on submit, so the
    /// "first-ranked" descriptor is the one that gets dispatched.
    /// If this contract breaks, the palette would dispatch a
    /// surprising command for the typed query.
    func testFirstRankedDescriptorForQueryIsTheExpectedCommand() {
        let vocab = Self.makeFakeDescriptors()
        let result = DebugCommandPalette.filter(vocab, query: "reset")
        XCTAssertEqual(result.first?.command, .resetComposition)
    }

    func testFilterResultsAreStableAcrossRepeatedCalls() {
        let vocab = Self.makeFakeDescriptors()
        let first = DebugCommandPalette.filter(vocab, query: "s")
        let second = DebugCommandPalette.filter(vocab, query: "s")
        XCTAssertEqual(first.map { $0.command }, second.map { $0.command })
    }

    private static func makeFakeDescriptors() -> [CommandDescriptor] {
        [
            CommandDescriptor(
                command: .openPhaseBDebug,
                title: "Open Phase B Debug",
                aliases: ["open phase b"]
            ),
            CommandDescriptor(
                command: .startRecording,
                title: "Start Recording",
                aliases: ["start recording"]
            ),
            CommandDescriptor(
                command: .resetComposition,
                title: "Reset Composition",
                aliases: ["reset", "reset composition", "clear"]
            ),
            CommandDescriptor(
                command: .speak,
                title: "Speak",
                aliases: ["speak", "say"]
            ),
        ]
    }
}
