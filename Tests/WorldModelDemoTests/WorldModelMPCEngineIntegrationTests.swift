import XCTest
import BCICore
@testable import WorldModelDemo

/// Exercises the REAL exported CoreML models end-to-end (load, compile,
/// batched predict) when they happen to be present on this machine.
/// `Models/` is gitignored (models are never shipped — see `CLAUDE.md`),
/// so this skips gracefully in any environment that hasn't run
/// `WorldModel/export_coreml.py` — matching how other Core ML-backed
/// suites in this repo have no happy-path test when the model isn't
/// shipped, just without losing the extra coverage on a machine that does
/// have it.
final class WorldModelMPCEngineIntegrationTests: XCTestCase {
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    func testFactoryResolvesLiveCoreMLAndPlanStepProducesFiniteAction() async throws {
        let modelsDir = repoRoot.appendingPathComponent("Models/WorldModelDemo").path
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: modelsDir + "/Encoder.mlpackage"),
            "Models/WorldModelDemo/ not present on this machine — run WorldModel/export_coreml.py"
        )

        let resolved = WorldModelDemoFactory.live(modelsDirectory: modelsDir)
        XCTAssertEqual(resolved.kind, .coreML)
        XCTAssertTrue(resolved.engine.isLive)

        let config = WorldModelMPCConfig()
        let result = try await resolved.engine.planStep(
            state: [0.8, 0.8, 0, 0],
            goalState: [-0.8, -0.8, 0, 0],
            previousAction: nil,
            velocity: 0,
            distanceToGoal: 2.263,
            maxAccel: 1.0,
            config: config
        )

        XCTAssertEqual(result.action.count, 2)
        XCTAssertTrue(result.action.allSatisfy { $0.isFinite })
        XCTAssertTrue(result.action.allSatisfy { abs($0) <= 1.0 + 1e-4 })
        XCTAssertTrue(result.diagnostics.effectiveSampleSize.isFinite)
        XCTAssertGreaterThan(result.diagnostics.effectiveSampleSize, 0)
        XCTAssertLessThanOrEqual(result.diagnostics.effectiveSampleSize, Double(config.numCandidates))
    }

    /// Regression test for a real bug: unlike the Python reference
    /// (`assert torch.isfinite(...)`), `planStep` had no finite-value guard
    /// at all, so `temperature == 0` drove the softmax to all-NaN weights,
    /// and `ParticleNavigatorEnv.step`'s clip silently turned that into a
    /// plausible-looking `maxAccel` action with no error anywhere.
    func testPlanStepThrowsOnZeroTemperatureInsteadOfSilentlyCorruptingAction() async throws {
        let modelsDir = repoRoot.appendingPathComponent("Models/WorldModelDemo").path
        try XCTSkipUnless(
            FileManager.default.fileExists(atPath: modelsDir + "/Encoder.mlpackage"),
            "Models/WorldModelDemo/ not present on this machine — run WorldModel/export_coreml.py"
        )

        let resolved = WorldModelDemoFactory.live(modelsDirectory: modelsDir)
        var config = WorldModelMPCConfig()
        config.temperature = 0
        config.adaptiveTemperature = false

        do {
            _ = try await resolved.engine.planStep(
                state: [0.8, 0.8, 0, 0],
                goalState: [-0.8, -0.8, 0, 0],
                previousAction: nil,
                velocity: 0,
                distanceToGoal: 2.263,
                maxAccel: 1.0,
                config: config
            )
            XCTFail("expected planStep to throw on a zero-temperature softmax, not return silently")
        } catch is BCIError {
            // Expected — the exact failure mode is secondary to "it throws
            // instead of returning a silently-corrupted finite action."
        }
    }
}
