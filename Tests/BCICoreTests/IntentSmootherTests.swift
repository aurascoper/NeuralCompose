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
            historySize: 5, activationCount: 3, selectActivationCount: 4, minConfidence: 0.5, refractoryWindows: 4
        ))
        let out = await s.ingest(pred(.jawClench))
        XCTAssertEqual(out, .idle)
    }

    func testRepeatedJawClenchAdvances() async {
        let s = IntentSmoother(config: .init(
            historySize: 5, activationCount: 3, selectActivationCount: 4, minConfidence: 0.5, refractoryWindows: 4
        ))
        _ = await s.ingest(pred(.jawClench))
        _ = await s.ingest(pred(.jawClench))
        let third = await s.ingest(pred(.jawClench))
        XCTAssertEqual(third, .advance)
    }

    func testHigherBarForSelect() async {
        let s = IntentSmoother(config: .init(
            historySize: 5, activationCount: 3, selectActivationCount: 4, minConfidence: 0.5, refractoryWindows: 6
        ))
        // 3 selects → still advance bar but not select bar.
        for _ in 0..<3 { _ = await s.ingest(pred(.select)) }
        // 4th select → triggers selectActive.
        let fourth = await s.ingest(pred(.select))
        XCTAssertEqual(fourth, .selectActive)
        // Next call is in refractory → idle.
        let next = await s.ingest(pred(.select))
        XCTAssertEqual(next, .idle)
    }

    func testAlternatingClassesDoNotAdvance() async {
        // 6-window history, rotating jaw / single / double @ high confidence.
        // No single class crosses activationCount=3, so the smoother must
        // remain idle even though *some* non-rest intent fires every window.
        let s = IntentSmoother(config: .init(
            historySize: 6, activationCount: 3, selectActivationCount: 4, minConfidence: 0.5, refractoryWindows: 4
        ))
        let cycle: [IntentClass] = [.jawClench, .singleBlink, .doubleBlink, .jawClench, .singleBlink, .doubleBlink]
        var last: SmoothedIntent = .idle
        for c in cycle {
            last = await s.ingest(pred(c, 0.9))
        }
        XCTAssertEqual(last, .idle, "alternating classes should not aggregate into advance")
    }

    func testLowConfidenceIsDiscarded() async {
        let s = IntentSmoother(config: .init(
            historySize: 5, activationCount: 3, selectActivationCount: 4, minConfidence: 0.7, refractoryWindows: 4
        ))
        for _ in 0..<5 { _ = await s.ingest(pred(.jawClench, 0.4)) }
        let final = await s.ingest(pred(.jawClench, 0.4))
        XCTAssertEqual(final, .idle)
    }
}
