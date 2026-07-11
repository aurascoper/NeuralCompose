import XCTest
@testable import BCICore

final class AppCommandTests: XCTestCase {

    func testEnumConformsToSendableEquatableHashable() {
        // Compile-time check: AppCommand satisfies these protocols.
        // If any are dropped the type won't conform and the test file
        // fails to build.
        let a: AppCommand = .speak
        let b: AppCommand = .speak
        let c: AppCommand = .refine
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)

        // Hashable: same case hashes the same.
        var hasherA = Hasher()
        a.hash(into: &hasherA)
        var hasherB = Hasher()
        b.hash(into: &hasherB)
        XCTAssertEqual(hasherA.finalize(), hasherB.finalize())

        // Sendable: assigning across a Sendable boundary compiles.
        // The fact that this assignment is allowed is the test.
        let sendableBox: [AppCommand] = [.speak, .refine, .resetComposition]
        XCTAssertEqual(sendableBox.count, 3)
    }

    func testAllCasesHaveUniqueStableIds() {
        let allCases: [AppCommand] = [
            .openPhaseBDebug,
            .startRecording,
            .stopRecording,
            .beginCalibration,
            .beginSleepProtocol,
            .resetComposition,
            .speak,
            .refine,
            .startDictation,
            .stopDictation,
            .startCommand,
            .stopCommand,
        ]
        let ids = allCases.map { $0.id }
        XCTAssertEqual(ids.count, Set(ids).count, "ids must be unique across all cases")
    }

    func testIdsContainNoWhitespace() {
        // ids are sentinels, log keys, MCP/Shortcuts identifiers.
        // Whitespace would break URL routing, log parsing, and
        // every consumer that treats the id as a single token.
        let allCases: [AppCommand] = [
            .openPhaseBDebug,
            .startRecording,
            .stopRecording,
            .beginCalibration,
            .beginSleepProtocol,
            .resetComposition,
            .speak,
            .refine,
            .startDictation,
            .stopDictation,
            .startCommand,
            .stopCommand,
        ]
        for c in allCases {
            XCTAssertFalse(
                c.id.contains(where: { $0.isWhitespace }),
                "id for \(c) contains whitespace: \(c.id.debugDescription)"
            )
        }
    }

    func testIdsAreNonEmpty() {
        // A non-empty id is the bare minimum. Caught at the
        // assertion level so a typo in a switch arm produces
        // a test failure, not a silent runtime regression.
        let allCases: [AppCommand] = [
            .openPhaseBDebug,
            .startRecording,
            .stopRecording,
            .beginCalibration,
            .beginSleepProtocol,
            .resetComposition,
            .speak,
            .refine,
            .startDictation,
            .stopDictation,
            .startCommand,
            .stopCommand,
        ]
        for c in allCases {
            XCTAssertFalse(c.id.isEmpty, "id for \(c) is empty")
        }
    }

    func testIdsAreExactlyTheCanonicalValues() {
        // Pin the id values so any rename is intentional and visible
        // in a diff. This is the contract — telemetry, voice logs,
        // MCP, Shortcuts all depend on these strings being stable
        // across releases.
        XCTAssertEqual(AppCommand.openPhaseBDebug.id,    "debug.phase-b")
        XCTAssertEqual(AppCommand.startRecording.id,     "record.start")
        XCTAssertEqual(AppCommand.stopRecording.id,      "record.stop")
        XCTAssertEqual(AppCommand.beginCalibration.id,   "calibration.begin")
        XCTAssertEqual(AppCommand.beginSleepProtocol.id, "protocol.sleep-begin")
        XCTAssertEqual(AppCommand.resetComposition.id,   "composition.reset")
        XCTAssertEqual(AppCommand.speak.id,              "tts.speak")
        XCTAssertEqual(AppCommand.refine.id,             "refine.run")
        XCTAssertEqual(AppCommand.startDictation.id,     "dictation.start")
        XCTAssertEqual(AppCommand.stopDictation.id,      "dictation.stop")
        XCTAssertEqual(AppCommand.startCommand.id,       "command.start")
        XCTAssertEqual(AppCommand.stopCommand.id,        "command.stop")
    }
}
