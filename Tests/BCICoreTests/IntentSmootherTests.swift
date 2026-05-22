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

    func testLowConfidenceIsDiscarded() async {
        let s = IntentSmoother(config: .init(
            historySize: 5, activationCount: 3, selectActivationCount: 4, minConfidence: 0.7, refractoryWindows: 4
        ))
        for _ in 0..<5 { _ = await s.ingest(pred(.jawClench, 0.4)) }
        let final = await s.ingest(pred(.jawClench, 0.4))
        XCTAssertEqual(final, .idle)
    }
}
