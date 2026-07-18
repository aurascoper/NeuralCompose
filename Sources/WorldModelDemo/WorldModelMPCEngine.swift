import Foundation
import BCICore

/// CoreML-backed Swift port of `WorldModel/mpc.py`'s
/// `sample_candidate_actions`/`score_candidates`/`plan_step`, kept
/// logic-for-logic with the Python source — including the terminal-cost
/// term, the smoothness term, the adaptive-temperature softmax, and the
/// stall-triggered candidate widening (wired but `stallVarianceMultiplier`
/// defaults to `1.0`/no-op, matching Python's evidenced default).
///
/// Batching: for each of `horizon` steps, all `numCandidates` candidates
/// are scored in ONE `WorldModelLatentPredictorModel.predictBatch` call —
/// `horizon` total CoreML calls per planning step, matching
/// `score_candidates`'s own one-batched-call-per-step loop shape (not
/// `horizon * numCandidates` individual calls).
public actor WorldModelMPCEngine: WorldModelDemoPlanning {
    public nonisolated let isLive = true
    public nonisolated let modelIdentifier: String

    private let onlineEncoder: WorldModelStateEncoderModel
    private let goalEncoder: WorldModelStateEncoderModel
    private let predictor: WorldModelLatentPredictorModel

    public init(
        onlineEncoder: WorldModelStateEncoderModel,
        goalEncoder: WorldModelStateEncoderModel,
        predictor: WorldModelLatentPredictorModel,
        modelIdentifier: String = "world-model-demo-coreml"
    ) {
        self.onlineEncoder = onlineEncoder
        self.goalEncoder = goalEncoder
        self.predictor = predictor
        self.modelIdentifier = modelIdentifier
    }

    public func planStep(
        state: [Float],
        goalState: [Float],
        previousAction: [Float]?,
        velocity: Float,
        distanceToGoal: Float,
        maxAccel: Float,
        config: WorldModelMPCConfig
    ) async throws -> WorldModelDemoPlanResult {
        let n = config.numCandidates
        precondition(n == predictor.batchSize, "numCandidates must match the exported predictor's fixed batch size")

        let stalled = velocity < Float(config.stallVelocityThreshold) && distanceToGoal > Float(config.stallDistanceThreshold)
        let effectiveMaxAccel = stalled ? maxAccel * Float(config.stallVarianceMultiplier) : maxAccel

        var candidateActions: [[[Float]]]
        if stalled {
            // stallWidenFraction has no range validation on WorldModelMPCConfig
            // -- clamp defensively so numNormal can never go negative and
            // crash `0..<count` with a Range precondition trap (mirrors the
            // identical fix in WorldModel/mpc.py::plan_step).
            let numWide = min(max(Int((Double(n) * config.stallWidenFraction).rounded()), 0), n)
            let numNormal = n - numWide
            var rng = SystemRandomNumberGenerator()
            let normal = Self.sampleCandidateActions(count: numNormal, horizon: config.horizon, maxAccel: maxAccel, using: &rng)
            let wide = Self.sampleCandidateActions(
                count: numWide, horizon: config.horizon,
                maxAccel: maxAccel * Float(config.stallVarianceMultiplier), using: &rng
            )
            candidateActions = normal + wide
        } else {
            var rng = SystemRandomNumberGenerator()
            candidateActions = Self.sampleCandidateActions(count: n, horizon: config.horizon, maxAccel: maxAccel, using: &rng)
        }

        let zStart = try await onlineEncoder.encode(state: state)
        let zGoal = try await goalEncoder.encode(state: goalState)

        var currentLatents = Array(repeating: zStart, count: n)
        var stateCost = [Double](repeating: 0, count: n)

        for t in 0..<config.horizon {
            let actionsAtT = candidateActions.map { $0[t] }
            currentLatents = try await predictor.predictBatch(latents: currentLatents, actions: actionsAtT)
            for i in 0..<n {
                stateCost[i] += Self.euclideanDistance(currentLatents[i], zGoal)
            }
        }

        var terminalCost = [Double](repeating: 0, count: n)
        for i in 0..<n {
            let d = Self.euclideanDistance(currentLatents[i], zGoal)
            terminalCost[i] = d * d
        }

        var smoothnessCost = [Double](repeating: 0, count: n)
        for i in 0..<n {
            var full = candidateActions[i]
            if let previousAction {
                full.insert(previousAction, at: 0)
            }
            var sum: Double = 0
            for t in 1..<full.count {
                sum += Self.euclideanDistance(full[t], full[t - 1])
            }
            smoothnessCost[i] = sum
        }

        if config.normalizeRunningCostByHorizon {
            for i in 0..<n { stateCost[i] /= Double(config.horizon) }
        }

        var totalCost = [Double](repeating: 0, count: n)
        for i in 0..<n {
            totalCost[i] = config.stateCostWeight * stateCost[i]
                + config.smoothnessCostWeight * smoothnessCost[i]
                + config.terminalCostWeight * terminalCost[i]
        }

        guard totalCost.allSatisfy({ $0.isFinite }) else {
            throw BCIError.worldModelDemoInferenceFailed(reason: "non-finite cost in MPC candidate scoring")
        }

        let costMin = totalCost.min() ?? 0
        let costMax = totalCost.max() ?? 0
        let costMean = totalCost.reduce(0, +) / Double(n)
        let variance = totalCost.reduce(0) { $0 + ($1 - costMean) * ($1 - costMean) } / Double(n)
        let costStd = variance.squareRoot()

        // config.temperature == 0, or an all-but-degenerate candidate batch
        // (costStd and minCostScale both ~0), would otherwise drive
        // temperatureEffective to 0 and every weight to NaN — unlike the
        // Python reference (`assert torch.isfinite(...)`), silently
        // clipping a NaN action into a plausible-looking maxAccel value
        // downstream instead of surfacing the failure.
        let costScale = config.adaptiveTemperature ? max(costStd, config.minCostScale) : 1.0
        guard costScale > 0 else {
            throw BCIError.worldModelDemoInferenceFailed(reason: "non-positive cost scale in MPC softmax")
        }
        let temperatureEffective = config.temperature * costScale
        guard temperatureEffective.isFinite, temperatureEffective > 0 else {
            throw BCIError.worldModelDemoInferenceFailed(reason: "non-finite or non-positive temperature in MPC softmax")
        }

        var weights = totalCost.map { exp(-($0 - costMin) / temperatureEffective) }
        let weightSum = weights.reduce(0, +)
        guard weightSum.isFinite, weightSum > 0 else {
            throw BCIError.worldModelDemoInferenceFailed(reason: "non-finite MPC softmax weight sum")
        }
        weights = weights.map { $0 / weightSum }

        let actionDim = candidateActions[0][0].count
        var blendedAction0 = [Float](repeating: 0, count: actionDim)
        for i in 0..<n {
            for d in 0..<actionDim {
                blendedAction0[d] += Float(weights[i]) * candidateActions[i][0][d]
            }
        }
        guard blendedAction0.allSatisfy({ $0.isFinite }) else {
            throw BCIError.worldModelDemoInferenceFailed(reason: "non-finite blended MPC action")
        }

        let effectiveSampleSize = 1.0 / weights.reduce(0) { $0 + $1 * $1 }

        let diagnostics = WorldModelDemoDiagnostics(
            costMin: costMin,
            costMean: costMean,
            costMax: costMax,
            costStd: costStd,
            temperatureEffective: temperatureEffective,
            effectiveSampleSize: effectiveSampleSize,
            stallDetected: stalled,
            effectiveMaxAccel: Double(effectiveMaxAccel),
            stateCostMean: config.stateCostWeight * (stateCost.reduce(0, +) / Double(n)),
            smoothnessCostMean: config.smoothnessCostWeight * (smoothnessCost.reduce(0, +) / Double(n)),
            terminalCostMean: config.terminalCostWeight * (terminalCost.reduce(0, +) / Double(n))
        )

        return WorldModelDemoPlanResult(action: blendedAction0, diagnostics: diagnostics)
    }

    static func sampleCandidateActions(
        count: Int, horizon: Int, maxAccel: Float, using rng: inout some RandomNumberGenerator
    ) -> [[[Float]]] {
        (0..<count).map { _ in
            (0..<horizon).map { _ in
                [Float.random(in: -maxAccel...maxAccel, using: &rng), Float.random(in: -maxAccel...maxAccel, using: &rng)]
            }
        }
    }

    static func euclideanDistance(_ a: [Float], _ b: [Float]) -> Double {
        var sum: Double = 0
        for i in 0..<a.count {
            let diff = Double(a[i]) - Double(b[i])
            sum += diff * diff
        }
        return sum.squareRoot()
    }
}
