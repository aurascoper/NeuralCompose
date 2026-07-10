import XCTest
@testable import BCICore

/// Covers `PipelineMode`'s decomposed Acquisition/Transport facets (a
/// refactor of the old combined `Source` enum — see the type's own doc
/// comment for why) and the F1 privacy-banner follow-up:
/// `PipelineMode.transportDetail` (e.g. OSC's bound port/interface) needs
/// to actually show up in `substitutionSummary`, not just exist as an
/// unused field.
final class PipelineModeTests: XCTestCase {

    func testSubstitutionSummaryAppendsTransportDetailWhenPresent() {
        let mode = PipelineMode(
            acquisition: .remotePhone,
            transport: .oscUDP,
            sourceProfile: .oscRemote,
            classifier: .coreML,
            predictor: .mlx,
            transportDetail: "UDP 5000 · utun3"
        )
        XCTAssertEqual(mode.substitutionSummary, "EEG: OSC Remote (network) (UDP 5000 · utun3)")
    }

    func testSubstitutionSummaryOmitsParenthesesWithoutTransportDetail() {
        let mode = PipelineMode(
            acquisition: .remotePhone,
            transport: .oscUDP,
            sourceProfile: .oscRemote,
            classifier: .coreML,
            predictor: .mlx
        )
        XCTAssertEqual(mode.substitutionSummary, "EEG: OSC Remote (network)")
    }

    func testFullyLiveSourceIgnoresTransportDetail() {
        // transportDetail is only ever meaningful for non-localMuse
        // acquisitions — substitutionSummary shouldn't surface it otherwise.
        let mode = PipelineMode(
            acquisition: .localMuse,
            transport: .ble,
            sourceProfile: .museSNativeBLE,
            classifier: .coreML,
            predictor: .mlx,
            transportDetail: "should not appear"
        )
        XCTAssertEqual(mode.substitutionSummary, "All systems live")
    }

    func testIsFullyLiveRequiresLocalMuseOverBLE() {
        let liveMode = PipelineMode(
            acquisition: .localMuse, transport: .ble, sourceProfile: .museSNativeBLE,
            classifier: .coreML, predictor: .mlx
        )
        XCTAssertTrue(liveMode.isFullyLive)

        // Same acquisition, but the remote-phone/OSC path — must not read
        // as "fully live" just because the classifier/predictor are real.
        let remoteMode = PipelineMode(
            acquisition: .remotePhone, transport: .oscUDP, sourceProfile: .oscRemote,
            classifier: .coreML, predictor: .mlx
        )
        XCTAssertFalse(remoteMode.isFullyLive)
    }

    func testAcquisitionBadgesStackAcquisitionAndTransport() {
        let mode = PipelineMode(
            acquisition: .remotePhone, transport: .oscUDP, sourceProfile: .oscRemote,
            classifier: .mock, predictor: .stub
        )
        XCTAssertEqual(mode.acquisitionBadges, ["Remote Phone", "OSC/UDP"])
    }

    func testAcquisitionBadgesOmitTransportWhenNone() {
        // Synthetic has no wire protocol — nothing meaningful to show as a
        // second badge, so acquisitionBadges should be a single entry, not
        // ["Synthetic", "—"].
        let mode = PipelineMode(
            acquisition: .synthetic, transport: .none, sourceProfile: .synthetic,
            classifier: .mock, predictor: .stub
        )
        XCTAssertEqual(mode.acquisitionBadges, ["Synthetic"])
    }
}
