import XCTest
@testable import WorldModelDemo

final class ParticleNavigatorEnvTests: XCTestCase {
    func testStepStaysInBoundsAndReturnsFourDims() {
        let config = WorldModelEnvConfig()
        let state: [Float] = [0.95, 0.95, 1.5, 1.5]
        let action: [Float] = [1.0, 1.0]

        let next = ParticleNavigatorEnv.step(state: state, action: action, config: config)

        XCTAssertEqual(next.count, 4)
        XCTAssertLessThanOrEqual(next[0], Float(config.arenaHalfExtent) + 1e-5)
        XCTAssertLessThanOrEqual(next[1], Float(config.arenaHalfExtent) + 1e-5)
        XCTAssertTrue(next.allSatisfy { $0.isFinite })
    }

    func testStepClampsActionToMaxAccel() {
        let config = WorldModelEnvConfig(maxAccel: 0.5)
        let state: [Float] = [0, 0, 0, 0]
        let next = ParticleNavigatorEnv.step(state: state, action: [10, 10], config: config)
        // vx/vy after one step of dt=0.1 at clipped accel 0.5 should be 0.05, not larger.
        XCTAssertEqual(next[2], 0.05, accuracy: 1e-4)
        XCTAssertEqual(next[3], 0.05, accuracy: 1e-4)
    }

    func testSampleGoalIsWithinArenaAndAtRest() {
        var rng = SystemRandomNumberGenerator()
        let config = WorldModelEnvConfig()
        let goal = ParticleNavigatorEnv.sampleGoal(config: config, using: &rng)
        XCTAssertEqual(goal.count, 4)
        XCTAssertLessThanOrEqual(abs(goal[0]), Float(config.arenaHalfExtent))
        XCTAssertLessThanOrEqual(abs(goal[1]), Float(config.arenaHalfExtent))
        XCTAssertEqual(goal[2], 0)
        XCTAssertEqual(goal[3], 0)
    }

    func testRestitutionBounceReversesAndScalesVelocity() {
        let config = WorldModelEnvConfig(maxAccel: 0, restitution: 0.6)
        // Already at the wall, moving further into it with zero action.
        let state: [Float] = [1.0, 0, 1.0, 0]
        let next = ParticleNavigatorEnv.step(state: state, action: [0, 0], config: config)
        XCTAssertEqual(next[0], 1.0, accuracy: 1e-5)
        XCTAssertEqual(next[2], -0.6, accuracy: 1e-5)
    }
}
