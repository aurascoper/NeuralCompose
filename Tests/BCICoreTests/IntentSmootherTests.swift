import XCTest
@testable import BCICore

final class IntentSmootherTests: XCTestCase {

    private func pred(_ c: IntentClass, _ conf: Float = 0.8, seq: UInt64 = 0) -> IntentPrediction {
        IntentPrediction(
            intent: c,
            confidence: conf,
            distribution: [c: conf],
            windowSequence: seq,
            endTimestamp: 0
        )
    }

    func testSingleHitDoesNotActivate() async {
        let s = IntentSmoother(config: .init(
            historySize: 5, activationCount: 3, dwellActivationCount: 4, minConfidence: 0.5, refractoryWindows: 4
        ))
        let out = await s.ingest(pred(.jawClench))
        XCTAssertEqual(out, .idle)
    }

    func testRepeatedJawClenchAdvances() async {
        let s = IntentSmoother(config: .init(
            historySize: 5, activationCount: 3, dwellActivationCount: 4, minConfidence: 0.5, refractoryWindows: 4
        ))
        _ = await s.ingest(pred(.jawClench))
        _ = await s.ingest(pred(.jawClench))
        let third = await s.ingest(pred(.jawClench))
        XCTAssertEqual(third, .advance)
    }

    func testHigherBarForDwellSelect() async {
        let s = IntentSmoother(config: .init(
            historySize: 5, activationCount: 3, dwellActivationCount: 4, minConfidence: 0.5, refractoryWindows: 6
        ))
        // 3 rest windows → still under the dwell bar.
        for _ in 0..<3 { _ = await s.ingest(pred(.rest)) }
        // 4th consecutive rest window → sustained dwell triggers selectActive.
        let fourth = await s.ingest(pred(.rest))
        XCTAssertEqual(fourth, .selectActive)
        // Next call is in refractory → idle.
        let next = await s.ingest(pred(.rest))
        XCTAssertEqual(next, .idle)
    }

    /// `.select` is a real model output class (the trained classifier still
    /// has 5 output logits) but is deliberately inert at the smoothing
    /// layer post-redesign — dwell-based rest replaced it as the commit
    /// trigger, and it must not silently also drive advance.
    func testSelectClassNeverTriggersAnything() async {
        let s = IntentSmoother(config: .init(
            historySize: 5, activationCount: 3, dwellActivationCount: 4, minConfidence: 0.5, refractoryWindows: 6
        ))
        var last: SmoothedIntent = .idle
        for _ in 0..<8 { last = await s.ingest(pred(.select, 0.95)) }
        XCTAssertEqual(last, .idle, "sustained .select predictions must not trigger selectActive or advance")
    }

    func testAlternatingClassesDoNotAdvance() async {
        // 6-window history, rotating jaw / single / double @ high confidence.
        // No single class crosses activationCount=3, so the smoother must
        // remain idle even though *some* non-rest intent fires every window.
        let s = IntentSmoother(config: .init(
            historySize: 6, activationCount: 3, dwellActivationCount: 4, minConfidence: 0.5, refractoryWindows: 4
        ))
        let cycle: [IntentClass] = [.jawClench, .singleBlink, .doubleBlink, .jawClench, .singleBlink, .doubleBlink]
        var last: SmoothedIntent = .idle
        for c in cycle {
            last = await s.ingest(pred(c, 0.9))
        }
        XCTAssertEqual(last, .idle, "alternating classes should not aggregate into advance")
    }

    /// Regression test for a real bug: with `refractoryWindows` (6) >
    /// `historySize` (5), ambient `.rest` accumulated purely during the
    /// post-commit cooldown used to refill the ring enough to immediately
    /// re-fire `.selectActive` the instant refractory ended — an
    /// unintended auto-commit with no deliberate dwell action from the
    /// user. Refractory predictions must not count toward the next dwell.
    func testAmbientRestDuringRefractoryDoesNotAutoRefire() async {
        let s = IntentSmoother(config: .init(
            historySize: 5, activationCount: 3, dwellActivationCount: 4, minConfidence: 0.55, refractoryWindows: 6
        ))
        // 3 rest windows stay under the dwell bar.
        for _ in 0..<3 { _ = await s.ingest(pred(.rest)) }
        // 4th consecutive rest window crosses the dwell bar -> selectActive,
        // entering a 6-window refractory period.
        let fourth = await s.ingest(pred(.rest))
        XCTAssertEqual(fourth, .selectActive)

        // Exactly `refractoryWindows` more windows of ambient .rest (the
        // user simply isn't gesturing right after the commit, which is
        // normal) -- all must stay idle, and must NOT silently refill the
        // dwell ring.
        for _ in 0..<6 {
            let out = await s.ingest(pred(.rest))
            XCTAssertEqual(out, .idle, "must stay idle throughout the refractory cooldown")
        }

        // Refractory has now fully elapsed. If ambient .rest during
        // refractory had counted toward the dwell ring (the bug), this call
        // would spuriously re-fire .selectActive with zero genuine
        // post-refractory dwell from the user.
        let firstAfterRefractory = await s.ingest(pred(.rest))
        XCTAssertEqual(firstAfterRefractory, .idle, "must not auto-refire immediately after refractory ends")
    }

    func testLowConfidenceIsDiscarded() async {
        let s = IntentSmoother(config: .init(
            historySize: 5, activationCount: 3, dwellActivationCount: 4, minConfidence: 0.7, refractoryWindows: 4
        ))
        for _ in 0..<5 { _ = await s.ingest(pred(.jawClench, 0.4)) }
        let final = await s.ingest(pred(.jawClench, 0.4))
        XCTAssertEqual(final, .idle)
    }
}
