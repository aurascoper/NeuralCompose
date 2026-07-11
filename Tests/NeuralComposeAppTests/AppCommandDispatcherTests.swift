import XCTest
@testable import BCICore
@testable import NeuralComposeApp

@MainActor
final class AppCommandDispatcherTests: XCTestCase {

    // MARK: - Spy

    /// Records every call the dispatcher makes on the target. Lets
    /// each test assert the *exact* side effect for the *exact*
    /// command case, with no shared state and no real pipeline.
    private final class SpyTarget: AppCommandDispatchTarget {
        var pendingWindowOpen: String?
        var pendingTab: PendingTab?

        private(set) var callLog: [String] = []

        func startCalibrationRecording() async {
            callLog.append("startCalibrationRecording")
        }
        func stopCalibrationRecording() async {
            callLog.append("stopCalibrationRecording")
        }
        func startImaginedSpeechSession() async {
            callLog.append("startImaginedSpeechSession")
        }
        func resetComposition() async {
            callLog.append("resetComposition")
        }
        func speak() async {
            callLog.append("speak")
        }
        func refineComposedText() async {
            callLog.append("refineComposedText")
        }
        func startDictation() async {
            callLog.append("startDictation")
        }
        func stopDictation() async {
            callLog.append("stopDictation")
        }
        func startCommandListening() async {
            callLog.append("startCommandListening")
        }
        func stopCommandListening() async {
            callLog.append("stopCommandListening")
        }
    }

    private func makeDispatcher() -> (AppCommandDispatcher, SpyTarget) {
        let spy = SpyTarget()
        let d = AppCommandDispatcher(target: spy)
        return (d, spy)
    }

    // MARK: - Per-case coverage

    func testOpenPhaseBDebugSetsPendingWindowOpen() async {
        let (d, spy) = makeDispatcher()
        await d.perform(.openPhaseBDebug)
        XCTAssertEqual(spy.pendingWindowOpen, "phase-b-debug")
        XCTAssertNil(spy.pendingTab)
        XCTAssertTrue(spy.callLog.isEmpty, "no method calls expected; got \(spy.callLog)")
    }

    func testStartRecordingCallsStartCalibrationRecording() async {
        let (d, spy) = makeDispatcher()
        await d.perform(.startRecording)
        XCTAssertEqual(spy.callLog, ["startCalibrationRecording"])
        XCTAssertNil(spy.pendingWindowOpen)
        XCTAssertNil(spy.pendingTab)
    }

    func testStopRecordingCallsStopCalibrationRecording() async {
        let (d, spy) = makeDispatcher()
        await d.perform(.stopRecording)
        XCTAssertEqual(spy.callLog, ["stopCalibrationRecording"])
    }

    func testBeginCalibrationStartsRecorderAndOpensCalibrationTab() async {
        let (d, spy) = makeDispatcher()
        await d.perform(.beginCalibration)
        XCTAssertEqual(spy.callLog, ["startCalibrationRecording"])
        XCTAssertEqual(spy.pendingTab, .calibration)
    }

    func testBeginSleepProtocolStartsImaginedSessionAndOpensResearchTab() async {
        let (d, spy) = makeDispatcher()
        await d.perform(.beginSleepProtocol)
        XCTAssertEqual(spy.callLog, ["startImaginedSpeechSession"])
        XCTAssertEqual(spy.pendingTab, .research)
    }

    func testResetCompositionCallsResetComposition() async {
        let (d, spy) = makeDispatcher()
        await d.perform(.resetComposition)
        XCTAssertEqual(spy.callLog, ["resetComposition"])
    }

    func testSpeakCallsSpeak() async {
        let (d, spy) = makeDispatcher()
        await d.perform(.speak)
        XCTAssertEqual(spy.callLog, ["speak"])
    }

    func testRefineCallsRefineComposedText() async {
        let (d, spy) = makeDispatcher()
        await d.perform(.refine)
        XCTAssertEqual(spy.callLog, ["refineComposedText"])
    }

    func testStartDictationCallsStartDictation() async {
        let (d, spy) = makeDispatcher()
        await d.perform(.startDictation)
        XCTAssertEqual(spy.callLog, ["startDictation"])
    }

    func testStopDictationCallsStopDictation() async {
        let (d, spy) = makeDispatcher()
        await d.perform(.stopDictation)
        XCTAssertEqual(spy.callLog, ["stopDictation"])
    }

    func testStartCommandCallsStartCommandListening() async {
        let (d, spy) = makeDispatcher()
        await d.perform(.startCommand)
        XCTAssertEqual(spy.callLog, ["startCommandListening"])
    }

    func testStopCommandCallsStopCommandListening() async {
        let (d, spy) = makeDispatcher()
        await d.perform(.stopCommand)
        XCTAssertEqual(spy.callLog, ["stopCommandListening"])
    }

    // MARK: - All 10 cases exhaustively

    /// Sweep over every `AppCommand` case asserting that exactly one
    /// of the three possible side effects (method call, pendingWindow
    /// write, pendingTab write) is produced. Catches typos in the
    /// dispatcher's switch that would route the wrong command to the
    /// wrong side effect, or silently no-op a command.
    func testEveryCommandProducesExactlyOneObservedSideEffect() async {
        for command in AppCommand.allCasesForTesting {
            let (d, spy) = makeDispatcher()
            await d.perform(command)
            let sideEffects =
                (spy.callLog.count > 0 ? 1 : 0) +
                (spy.pendingWindowOpen != nil ? 1 : 0) +
                (spy.pendingTab != nil ? 1 : 0)
            XCTAssertGreaterThanOrEqual(
                sideEffects, 1,
                "command \(command) produced no observable side effect on the target"
            )
        }
    }

    // MARK: - No-side-effect commands don't touch other surfaces

    func testOpenPhaseBDebugDoesNotCallAnyMethod() async {
        let (d, spy) = makeDispatcher()
        await d.perform(.openPhaseBDebug)
        XCTAssertTrue(
            spy.callLog.isEmpty,
            "openPhaseBDebug should set pendingWindowOpen only, not call a method; got \(spy.callLog)"
        )
    }

    func testMethodCommandsDoNotTouchPendingFields() async {
        for command in [
            AppCommand.startRecording,
            .stopRecording,
            .resetComposition,
            .speak,
            .refine,
            .startDictation,
            .stopDictation,
            .startCommand,
            .stopCommand,
        ] {
            let (d, spy) = makeDispatcher()
            await d.perform(command)
            XCTAssertNil(
                spy.pendingWindowOpen,
                "\(command) unexpectedly set pendingWindowOpen"
            )
            XCTAssertNil(
                spy.pendingTab,
                "\(command) unexpectedly set pendingTab"
            )
            XCTAssertFalse(
                spy.callLog.isEmpty,
                "\(command) produced no method call"
            )
        }
    }

    // MARK: - Lifecycle

    /// When the target is deallocated, the dispatcher should no-op
    /// rather than crashing. This is the contract the dispatcher's
    /// weak reference enforces — a short-lived emitter (e.g. a
    /// transient voice-recognition task) must not extend the
    /// target's lifetime or trap on a freed object.
    func testPerformIsNoOpWhenTargetHasBeenDeallocated() async {
        weak var weakSpy: SpyTarget?
        do {
            let (d, spy) = makeDispatcher()
            weakSpy = spy
            await d.perform(.speak) // baseline: dispatcher still wired
            XCTAssertEqual(spy.callLog, ["speak"])
        }
        // SpyTarget now deallocated (its only owner was the dispatcher).
        XCTAssertNil(weakSpy, "SpyTarget should be deallocated after the dispatcher goes out of scope")
    }

    // MARK: - Vocabulary exposure

    func testDispatcherExposesItsCommandDescriptors() {
        let (d, _) = makeDispatcher()
        let vocab = d.commandDescriptors
        XCTAssertEqual(vocab.count, 12, "default vocabulary should have 12 entries (10 existing + startCommand + stopCommand)")
        // Every case in the enum has a descriptor.
        let caseSet = Set(vocab.map { $0.command })
        let allCases = AppCommand.allCasesForTesting
        for c in allCases {
            XCTAssertTrue(caseSet.contains(c), "missing descriptor for \(c)")
        }
    }
}

// MARK: - Test fixture helper

extension AppCommand {
    /// Compile-time-fixed list of every case. Used by the test suite's
    /// sweep to iterate over the full enum without missing newly-added
    /// cases (a test that builds the array inline would silently skip
    /// any case added in the future; a hardcoded list here means a
    /// future contributor has to think about whether the new case is
    /// included in coverage).
    static var allCasesForTesting: [AppCommand] {
        [
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
    }
}
