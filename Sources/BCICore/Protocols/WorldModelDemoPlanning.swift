import Foundation

/// One MPPI planning step for the synthetic-task World Model demo (see
/// `Sources/WorldModelDemo/` and `WorldModel/README.md`). Protocol lives in
/// `BCICore` following the standard `IntentClassifying`/`NextWordPredicting`
/// precedent — concrete conformers (a CoreML-backed engine, and a baseline
/// fallback) live in the dedicated `WorldModelDemo` target.
///
/// This has nothing to do with real EEG data or the production typing
/// path — `state`/`goalState`/`previousAction` are the synthetic 2D
/// particle-navigation task's own `[x, y, vx, vy]`/`[ax, ay]` vectors.
public protocol WorldModelDemoPlanning: Sendable {
    var isLive: Bool { get }
    var modelIdentifier: String { get }

    func planStep(
        state: [Float],
        goalState: [Float],
        previousAction: [Float]?,
        velocity: Float,
        distanceToGoal: Float,
        maxAccel: Float,
        config: WorldModelMPCConfig
    ) async throws -> WorldModelDemoPlanResult
}

public struct WorldModelDemoPlanResult: Sendable {
    public let action: [Float]
    public let diagnostics: WorldModelDemoDiagnostics

    public init(action: [Float], diagnostics: WorldModelDemoDiagnostics) {
        self.action = action
        self.diagnostics = diagnostics
    }
}

/// Mirrors `mpc.py::plan_step`'s returned diagnostics dict, field-for-field.
public struct WorldModelDemoDiagnostics: Sendable {
    public let costMin: Double
    public let costMean: Double
    public let costMax: Double
    public let costStd: Double
    public let temperatureEffective: Double
    public let effectiveSampleSize: Double
    public let stallDetected: Bool
    public let effectiveMaxAccel: Double
    public let stateCostMean: Double
    public let smoothnessCostMean: Double
    public let terminalCostMean: Double

    public init(
        costMin: Double,
        costMean: Double,
        costMax: Double,
        costStd: Double,
        temperatureEffective: Double,
        effectiveSampleSize: Double,
        stallDetected: Bool,
        effectiveMaxAccel: Double,
        stateCostMean: Double,
        smoothnessCostMean: Double,
        terminalCostMean: Double
    ) {
        self.costMin = costMin
        self.costMean = costMean
        self.costMax = costMax
        self.costStd = costStd
        self.temperatureEffective = temperatureEffective
        self.effectiveSampleSize = effectiveSampleSize
        self.stallDetected = stallDetected
        self.effectiveMaxAccel = effectiveMaxAccel
        self.stateCostMean = stateCostMean
        self.smoothnessCostMean = smoothnessCostMean
        self.terminalCostMean = terminalCostMean
    }
}
