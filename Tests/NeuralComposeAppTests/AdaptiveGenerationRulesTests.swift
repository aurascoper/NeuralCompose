import XCTest
@testable import BCICore
@testable import NeuralComposeApp

final class AdaptiveGenerationRulesTests: XCTestCase {

    func testHealthyAndNilMatchRawDefault() {
        XCTAssertEqual(SignalQualityGenerationRules.adaptation(for: nil), .raw)
        XCTAssertEqual(SignalQualityGenerationRules.adaptation(for: .healthy), .raw)
    }

    func testPoorSimplifiesModerately() {
        let a = SignalQualityGenerationRules.adaptation(for: .poor)
        XCTAssertEqual(a.maxCandidates, 3)
        XCTAssertEqual(a.temperature, 0.5)
        XCTAssertFalse(a.styleInstruction.isEmpty)
    }

    func testLostSimplifiesStrongly() {
        let a = SignalQualityGenerationRules.adaptation(for: .lost)
        XCTAssertEqual(a.maxCandidates, 2)
        XCTAssertEqual(a.temperature, 0.3)
        XCTAssertFalse(a.styleInstruction.isEmpty)
    }

    /// `.lost` should never be *less* conservative than `.poor` — a
    /// worse-quality signal must not unlock a wider or hotter candidate set.
    func testLostIsAtLeastAsConservativeAsPoor() {
        let poor = SignalQualityGenerationRules.adaptation(for: .poor)
        let lost = SignalQualityGenerationRules.adaptation(for: .lost)
        XCTAssertLessThanOrEqual(lost.maxCandidates, poor.maxCandidates)
        XCTAssertLessThanOrEqual(lost.temperature, poor.temperature)
    }
}
