import XCTest
@testable import BCICore

/// Covers the F1 privacy-banner follow-up: `PipelineMode.transportDetail`
/// (e.g. OSC's bound port/interface) needs to actually show up in
/// `substitutionSummary`, not just exist as an unused field.
final class PipelineModeTests: XCTestCase {

    func testSubstitutionSummaryAppendsTransportDetailWhenPresent() {
        let mode = PipelineMode(
            source: .oscRemote,
            sourceProfile: .oscRemote,
            classifier: .coreML,
            predictor: .mlx,
            transportDetail: "UDP 5000 · utun3"
        )
        XCTAssertEqual(mode.substitutionSummary, "EEG: OSC Remote (network) (UDP 5000 · utun3)")
    }

    func testSubstitutionSummaryOmitsParenthesesWithoutTransportDetail() {
        let mode = PipelineMode(
            source: .oscRemote,
            sourceProfile: .oscRemote,
            classifier: .coreML,
            predictor: .mlx
        )
        XCTAssertEqual(mode.substitutionSummary, "EEG: OSC Remote (network)")
    }

    func testFullyLiveSourceIgnoresTransportDetail() {
        // transportDetail is only ever meaningful for non-brainflowMuse
        // sources — substitutionSummary shouldn't surface it otherwise.
        let mode = PipelineMode(
            source: .brainflowMuse,
            sourceProfile: .museSNativeBLE,
            classifier: .coreML,
            predictor: .mlx,
            transportDetail: "should not appear"
        )
        XCTAssertEqual(mode.substitutionSummary, "All systems live")
    }
}
