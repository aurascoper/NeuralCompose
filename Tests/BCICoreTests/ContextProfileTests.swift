import XCTest
@testable import BCICore

/// The three profiles are relative locations in the behavioral space; these
/// assert the *ordering* the design calls for, not brittle absolute values.
final class ContextProfileTests: XCTestCase {

    private let focused = ContextProfile.focused.tuning
    private let reflective = ContextProfile.reflective.tuning
    private let contemplative = ContextProfile.contemplative.tuning

    func testReflectiveIsExactlyTheShippedDefault() {
        XCTAssertEqual(ContextProfile.reflective.tuning.weights, DialecticalWeights.balanced)
        XCTAssertEqual(ContextProfile.reflective.maxConsecutiveSilence, 3)
    }

    func testFocusedResolvesReadilyAndRarelyFallsSilent() {
        XCTAssertLessThan(focused.synthesisHighBar, reflective.synthesisHighBar,
                          "focused synthesizes more readily")
        XCTAssertGreaterThan(focused.highTension, reflective.highTension,
                             "focused needs more tension before it will fall silent (rarely does)")
        XCTAssertLessThan(focused.weights.novelty, reflective.weights.novelty,
                          "focused explores less")
    }

    func testContemplativeIsLessNotDreamerPlusPlus() {
        // Suppressed synthesis, more silence, slower — the point is non-elaboration.
        XCTAssertGreaterThan(contemplative.synthesisHighBar, reflective.synthesisHighBar,
                             "contemplative is reluctant to resolve")
        XCTAssertGreaterThan(contemplative.synthesisSustainK, reflective.synthesisSustainK,
                             "…and waits longer before a convergence synthesis")
        XCTAssertLessThan(contemplative.highTension, reflective.highTension,
                          "contemplative falls silent more readily")
        XCTAssertGreaterThan(ContextProfile.contemplative.maxConsecutiveSilence,
                             ContextProfile.reflective.maxConsecutiveSilence,
                             "…and tolerates longer silence")
        XCTAssertGreaterThan(ContextProfile.contemplative.interTurnDelayNanos,
                             ContextProfile.reflective.interTurnDelayNanos,
                             "…at a slower cadence")
        XCTAssertLessThan(contemplative.weights.novelty, reflective.weights.novelty,
                          "…with reduced novelty pressure, not increased")
    }

    func testLoopConfigCarriesProfileCadenceAndPreservesBaseFields() {
        let cfg = ContextProfile.contemplative.loopConfig()
        XCTAssertEqual(cfg.maxConsecutiveSilence, 6)
        XCTAssertEqual(cfg.interTurnDelayNanos, 6_000_000_000)
        XCTAssertEqual(cfg.maxTokens, HypnagogicDialecticLoop.Config().maxTokens, "non-cadence fields preserved")
    }

    func testWitnessEnabledOnlyForReflective() {
        // The single declaration of "Reflective is the introspective rung." The
        // Tuning stays default (see testReflectiveIsExactlyTheShippedDefault); the
        // differentiation is this flag, threaded into loopConfig.
        XCTAssertTrue(ContextProfile.reflective.witnessEnabled)
        XCTAssertFalse(ContextProfile.focused.witnessEnabled)
        XCTAssertFalse(ContextProfile.contemplative.witnessEnabled)
        XCTAssertTrue(ContextProfile.reflective.loopConfig().witnessEnabled)
        XCTAssertFalse(ContextProfile.focused.loopConfig().witnessEnabled)
    }
}
