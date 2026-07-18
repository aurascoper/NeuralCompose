import XCTest
import BCICore

/// Pins the 1:1 field-for-field port of `WorldModel/mpc.py::MPCConfig`'s
/// defaults — if a Python-side default changes without a matching Swift
/// change, this test should fail rather than silently drift.
final class WorldModelMPCConfigTests: XCTestCase {
    func testDefaultsMatchPythonMPCConfig() {
        let config = WorldModelMPCConfig()
        XCTAssertEqual(config.horizon, 10)
        XCTAssertEqual(config.numCandidates, 512)
        XCTAssertEqual(config.temperature, 0.45, accuracy: 1e-9)
        XCTAssertEqual(config.stateCostWeight, 1.0, accuracy: 1e-9)
        XCTAssertEqual(config.smoothnessCostWeight, 0.1, accuracy: 1e-9)
        XCTAssertEqual(config.terminalCostWeight, 2.0, accuracy: 1e-9)
        XCTAssertEqual(config.stallVelocityThreshold, 0.1, accuracy: 1e-9)
        XCTAssertEqual(config.stallDistanceThreshold, 0.5, accuracy: 1e-9)
        XCTAssertEqual(config.stallVarianceMultiplier, 1.0, accuracy: 1e-9)
        XCTAssertEqual(config.stallWidenFraction, 0.25, accuracy: 1e-9)
        XCTAssertTrue(config.adaptiveTemperature)
        XCTAssertEqual(config.minCostScale, 1e-3, accuracy: 1e-12)
        XCTAssertFalse(config.normalizeRunningCostByHorizon)
    }
}
