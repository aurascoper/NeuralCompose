import XCTest
import BCICore
@testable import WorldModelDemo

final class BaselineWorldModelDemoPlannerTests: XCTestCase {
    func testStepsTowardGoal() async throws {
        let planner = BaselineWorldModelDemoPlanner()
        XCTAssertFalse(planner.isLive)

        let result = try await planner.planStep(
            state: [0, 0, 0, 0],
            goalState: [1, 0, 0, 0],
            previousAction: nil,
            velocity: 0,
            distanceToGoal: 1,
            maxAccel: 1.0,
            config: WorldModelMPCConfig()
        )

        XCTAssertEqual(result.action.count, 2)
        // Goal is directly on +x, so the action should point almost entirely +x.
        XCTAssertGreaterThan(result.action[0], 0.9)
        XCTAssertEqual(result.action[1], 0, accuracy: 1e-5)
    }

    func testZeroDistanceProducesZeroAction() async throws {
        let planner = BaselineWorldModelDemoPlanner()
        let result = try await planner.planStep(
            state: [0.5, 0.5, 0, 0],
            goalState: [0.5, 0.5, 0, 0],
            previousAction: nil,
            velocity: 0,
            distanceToGoal: 0,
            maxAccel: 1.0,
            config: WorldModelMPCConfig()
        )
        XCTAssertEqual(result.action, [0, 0])
    }
}
