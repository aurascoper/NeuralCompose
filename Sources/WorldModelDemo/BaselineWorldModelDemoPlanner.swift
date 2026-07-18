import Foundation
import BCICore

/// Non-CoreML fallback: a simple proportional controller steering directly
/// at the goal in real position space — no latent space, no learned
/// weights. Used when `Models/WorldModelDemo/` is absent, mirroring
/// `MockIntentClassifier`'s "has real, if simplified, behavior" shape
/// (not a pure no-op) — a dead demo window would be a worse fallback than
/// a visibly-simpler controller.
public struct BaselineWorldModelDemoPlanner: WorldModelDemoPlanning {
    public let isLive = false
    public let modelIdentifier = "baseline (no CoreML models found)"

    public init() {}

    public func planStep(
        state: [Float],
        goalState: [Float],
        previousAction: [Float]?,
        velocity: Float,
        distanceToGoal: Float,
        maxAccel: Float,
        config: WorldModelMPCConfig
    ) async throws -> WorldModelDemoPlanResult {
        let dx = goalState[0] - state[0]
        let dy = goalState[1] - state[1]
        let norm = (dx * dx + dy * dy).squareRoot()
        let action: [Float]
        if norm > 1e-6 {
            action = [max(-maxAccel, min(maxAccel, dx / norm * maxAccel)),
                      max(-maxAccel, min(maxAccel, dy / norm * maxAccel))]
        } else {
            action = [0, 0]
        }
        let diagnostics = WorldModelDemoDiagnostics(
            costMin: 0, costMean: 0, costMax: 0, costStd: 0, temperatureEffective: 0,
            effectiveSampleSize: 0, stallDetected: false, effectiveMaxAccel: Double(maxAccel),
            stateCostMean: 0, smoothnessCostMean: 0, terminalCostMean: 0
        )
        return WorldModelDemoPlanResult(action: action, diagnostics: diagnostics)
    }
}
