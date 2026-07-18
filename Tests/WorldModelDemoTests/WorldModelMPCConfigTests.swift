import XCTest
import BCICore

/// Pins `WorldModelMPCConfig`'s own current defaults against hardcoded
/// literals — a regression test for THIS struct changing unintentionally.
///
/// It does NOT read or compare against `WorldModel/mpc.py::MPCConfig` in
/// any way, so it cannot catch the Python side drifting out of the 1:1
/// field-for-field sync that struct's doc comment requires — that sync is
/// still enforced only by convention/code review. `numCandidates`
/// specifically is additionally checked against the exported CoreML
/// predictor's actual batch size at resolve time
/// (`WorldModelDemoFactory.live()`), which is what actually prevents a
/// drift there from crashing the demo via `WorldModelMPCEngine.planStep`'s
/// `precondition`.
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
