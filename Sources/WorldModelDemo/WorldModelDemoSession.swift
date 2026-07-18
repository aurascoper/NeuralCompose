import Foundation
import BCICore

/// One record per `tick()` — enough for the demo view to render the
/// spatial trajectory, MPPI diagnostics, and latency panels without
/// reaching back into the session's internals.
public struct WorldModelDemoStepRecord: Sendable {
    public let scenarioName: String
    public let state: [Float]
    public let goal: [Float]
    public let action: [Float]
    public let diagnostics: WorldModelDemoDiagnostics
    public let planningLatencyMs: Double
    public let reached: Bool
    public let stepIndex: Int
}

/// Orchestrator mirroring `mpc.py::run_episode`'s loop shape (not its
/// 100-episode aggregation): owns current state/goal/previousAction, calls
/// the injected planner then `ParticleNavigatorEnv.step`, and auto-advances
/// to the next fixed scenario on reaching the goal or hitting the step
/// budget.
@MainActor
public final class WorldModelDemoSession {
    private let engine: any WorldModelDemoPlanning
    private let envConfig: WorldModelEnvConfig
    private let mpcConfig: WorldModelMPCConfig
    private let goalTolerance: Float
    private let maxEpisodeSteps: Int

    private var scenarios: [WorldModelDemoScenario]
    private var scenarioIndex = 0
    private var state: [Float]
    private var previousAction: [Float]?
    private var stepIndex = 0
    private var rng = SystemRandomNumberGenerator()

    public init(
        engine: any WorldModelDemoPlanning,
        scenarios: [WorldModelDemoScenario] = WorldModelDemoScenarios.all,
        envConfig: WorldModelEnvConfig = WorldModelEnvConfig(),
        mpcConfig: WorldModelMPCConfig = WorldModelMPCConfig(),
        goalTolerance: Float = 0.1,
        maxEpisodeSteps: Int = 50
    ) {
        self.engine = engine
        self.scenarios = scenarios
        self.envConfig = envConfig
        self.mpcConfig = mpcConfig
        self.goalTolerance = goalTolerance
        self.maxEpisodeSteps = maxEpisodeSteps
        self.state = scenarios.first?.start ?? [0, 0, 0, 0]
    }

    private var currentScenario: WorldModelDemoScenario {
        scenarios[scenarioIndex % scenarios.count]
    }

    public func tick() async throws -> WorldModelDemoStepRecord {
        let scenario = currentScenario
        let goal = scenario.goal
        let dx = state[0] - goal[0]
        let dy = state[1] - goal[1]
        let distanceToGoal = (dx * dx + dy * dy).squareRoot()
        let velocity = (state[2] * state[2] + state[3] * state[3]).squareRoot()

        let reachedAlready = distanceToGoal < goalTolerance
        let stepBudgetExceeded = stepIndex >= maxEpisodeSteps

        if reachedAlready || stepBudgetExceeded {
            advanceToNextScenario()
            return try await tick()
        }

        let start = DispatchTime.now()
        let result = try await engine.planStep(
            state: state,
            goalState: goal,
            previousAction: previousAction,
            velocity: velocity,
            distanceToGoal: distanceToGoal,
            maxAccel: Float(envConfig.maxAccel),
            config: mpcConfig
        )
        let latencyMs = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000

        previousAction = result.action
        state = ParticleNavigatorEnv.step(state: state, action: result.action, config: envConfig)
        stepIndex += 1

        let newDistance = (
            (state[0] - goal[0]) * (state[0] - goal[0]) + (state[1] - goal[1]) * (state[1] - goal[1])
        ).squareRoot()

        return WorldModelDemoStepRecord(
            scenarioName: scenario.name,
            state: state,
            goal: goal,
            action: result.action,
            diagnostics: result.diagnostics,
            planningLatencyMs: latencyMs,
            reached: newDistance < goalTolerance,
            stepIndex: stepIndex
        )
    }

    private func advanceToNextScenario() {
        scenarioIndex += 1
        state = currentScenario.start
        previousAction = nil
        stepIndex = 0
    }
}
