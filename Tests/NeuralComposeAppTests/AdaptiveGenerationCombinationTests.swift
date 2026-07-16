import XCTest
@testable import BCICore
@testable import NeuralComposeApp

final class AdaptiveGenerationCombinationTests: XCTestCase {

    /// The artifact gate only rejects too-*high*-amplitude windows, not a
    /// disconnected electrode — so a spectral opinion could otherwise
    /// spuriously survive on a dead channel. `.lost` must always win,
    /// regardless of what the spectral estimator says.
    func testLostSignalQualityIsAnAbsoluteFloorRegardlessOfSpectralState() {
        for spectral in [nil] + SpectralState.allCases.map(Optional.some) {
            let result = AdaptiveGenerationCombination.adaptation(
                signalQuality: .lost, spectralState: spectral
            )
            XCTAssertEqual(result, SignalQualityGenerationRules.adaptation(for: .lost))
        }
    }

    func testPresentSpectralStateOverridesHealthySignalQuality() {
        let result = AdaptiveGenerationCombination.adaptation(
            signalQuality: .healthy, spectralState: .highCognitiveLoad
        )
        XCTAssertEqual(result, SpectralGenerationRules.adaptation(for: .highCognitiveLoad))
        XCTAssertNotEqual(result, .raw)
    }

    func testPresentSpectralStateOverridesPoorSignalQuality() {
        let result = AdaptiveGenerationCombination.adaptation(
            signalQuality: .poor, spectralState: .relaxedWakefulness
        )
        // .relaxedWakefulness maps to .raw in SpectralGenerationRules — the
        // spectral opinion wins even though it's "less conservative" than
        // .poor's own hedge, since .poor (unlike .lost) isn't a floor.
        XCTAssertEqual(result, .raw)
    }

    func testNilSpectralStateFallsBackToSignalQualityTable() {
        for quality: SignalQuality? in [nil, .healthy, .poor, .lost] {
            let result = AdaptiveGenerationCombination.adaptation(
                signalQuality: quality, spectralState: nil
            )
            XCTAssertEqual(result, SignalQualityGenerationRules.adaptation(for: quality))
        }
    }
}
