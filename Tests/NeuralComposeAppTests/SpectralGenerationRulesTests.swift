import XCTest
@testable import BCICore
@testable import NeuralComposeApp

final class SpectralGenerationRulesTests: XCTestCase {

    func testHighCognitiveLoadSimplifies() {
        let a = SpectralGenerationRules.adaptation(for: .highCognitiveLoad)
        XCTAssertNotEqual(a, .raw)
        XCTAssertLessThan(a.maxCandidates, GenerationAdaptation.raw.maxCandidates)
    }

    func testDrowsyFatiguedSimplifies() {
        let a = SpectralGenerationRules.adaptation(for: .drowsyFatigued)
        XCTAssertNotEqual(a, .raw)
        XCTAssertLessThan(a.maxCandidates, GenerationAdaptation.raw.maxCandidates)
    }

    /// Conservative-only, decided: the new signal only ever narrows output,
    /// it never unlocks something wider/hotter than the default.
    func testRelaxedEngagedAndNeutralAllMapToRaw() {
        XCTAssertEqual(SpectralGenerationRules.adaptation(for: .relaxedWakefulness), .raw)
        XCTAssertEqual(SpectralGenerationRules.adaptation(for: .engagedFocused), .raw)
        XCTAssertEqual(SpectralGenerationRules.adaptation(for: .neutralBaseline), .raw)
    }

    func testNoStateEverExceedsRawCandidatesOrTemperature() {
        for state in SpectralState.allCases {
            let a = SpectralGenerationRules.adaptation(for: state)
            XCTAssertLessThanOrEqual(a.maxCandidates, GenerationAdaptation.raw.maxCandidates)
            XCTAssertLessThanOrEqual(a.temperature, GenerationAdaptation.raw.temperature)
        }
    }
}
