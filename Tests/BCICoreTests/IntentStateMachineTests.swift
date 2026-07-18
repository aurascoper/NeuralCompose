import XCTest
@testable import BCICore

final class IntentStateMachineTests: XCTestCase {

    func testIdleIgnoresEverythingExceptPredictionsReady() {
        var fsm = IntentStateMachine()
        XCTAssertEqual(fsm.step(.smoothed(.advance)), .noop)
        XCTAssertEqual(fsm.step(.timerTick), .noop)
        XCTAssertEqual(fsm.step(.smoothed(.selectActive)), .noop)
        XCTAssertEqual(fsm.state, .idle)
        XCTAssertEqual(fsm.step(.predictionsReady), .noop)
        XCTAssertEqual(fsm.state, .showingCandidates)
    }

    /// `.timerTick` is a deliberate no-op while showing candidates — see
    /// `IntentStateMachine`'s doc comment. Advancing is exclusively
    /// gesture-driven (`.smoothed(.advance)`); a blind auto-cycle would
    /// defeat `IntentSmoother`'s dwell-based select, which needs the
    /// highlight to hold still for several seconds of sustained rest.
    func testTimerTickDoesNotAdvanceWhileShowingCandidates() {
        var fsm = IntentStateMachine()
        _ = fsm.step(.predictionsReady)
        XCTAssertEqual(fsm.step(.timerTick), .noop)
        XCTAssertEqual(fsm.step(.timerTick), .noop)
        XCTAssertEqual(fsm.state, .showingCandidates, "must not have transitioned or acted on repeated ticks")
    }

    func testShowingCandidatesAdvancesAndCommits() {
        var fsm = IntentStateMachine()
        _ = fsm.step(.predictionsReady)
        XCTAssertEqual(fsm.step(.smoothed(.advance)), .advanceHighlight)
        XCTAssertEqual(fsm.step(.smoothed(.selectActive)), .commitActive)
        XCTAssertEqual(fsm.state, .predicting)
    }

    func testPredictingDropsAllSignalsUntilReady() {
        var fsm = IntentStateMachine()
        _ = fsm.step(.predictionsReady)
        _ = fsm.step(.smoothed(.selectActive))
        XCTAssertEqual(fsm.state, .predicting)
        XCTAssertEqual(fsm.step(.timerTick), .noop)
        XCTAssertEqual(fsm.step(.smoothed(.selectActive)), .noop)
        XCTAssertEqual(fsm.step(.predictionsReady), .noop)
        XCTAssertEqual(fsm.state, .showingCandidates)
    }

    func testResetReturnsToIdle() {
        var fsm = IntentStateMachine()
        _ = fsm.step(.predictionsReady)
        _ = fsm.step(.reset)
        XCTAssertEqual(fsm.state, .idle)
    }
}
