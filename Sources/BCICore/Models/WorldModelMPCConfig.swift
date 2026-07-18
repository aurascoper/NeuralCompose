import Foundation

/// 1:1 field-for-field port of `WorldModel/mpc.py::MPCConfig`. Keep every
/// field name/default in sync with the Python dataclass by hand — this is
/// a porting-correctness requirement, not a style preference. If
/// `mpc.py`'s `MPCConfig` gains, loses, or renames a field, this struct
/// must change with it in the same change.
///
/// `numCandidates` is additionally constrained by
/// `WorldModel/export_coreml.py`: `LatentPredictor.mlpackage` is exported
/// with a FIXED batch dimension (512, matching this struct's default) so
/// the Swift planner can score every candidate in one CoreML call per
/// horizon step. Changing `numCandidates` here requires regenerating that
/// export to match — this is a real coupling, not just a tunable default.
public struct WorldModelMPCConfig: Sendable, Equatable {
    public var horizon: Int
    public var numCandidates: Int
    public var temperature: Double
    public var stateCostWeight: Double
    public var smoothnessCostWeight: Double
    public var terminalCostWeight: Double
    public var stallVelocityThreshold: Double
    public var stallDistanceThreshold: Double
    public var stallVarianceMultiplier: Double
    public var stallWidenFraction: Double
    public var adaptiveTemperature: Bool
    public var minCostScale: Double
    public var normalizeRunningCostByHorizon: Bool

    public init(
        horizon: Int = 10,
        numCandidates: Int = 512,
        temperature: Double = 0.45,
        stateCostWeight: Double = 1.0,
        smoothnessCostWeight: Double = 0.1,
        terminalCostWeight: Double = 2.0,
        stallVelocityThreshold: Double = 0.1,
        stallDistanceThreshold: Double = 0.5,
        stallVarianceMultiplier: Double = 1.0,
        stallWidenFraction: Double = 0.25,
        adaptiveTemperature: Bool = true,
        minCostScale: Double = 1e-3,
        normalizeRunningCostByHorizon: Bool = false
    ) {
        self.horizon = horizon
        self.numCandidates = numCandidates
        self.temperature = temperature
        self.stateCostWeight = stateCostWeight
        self.smoothnessCostWeight = smoothnessCostWeight
        self.terminalCostWeight = terminalCostWeight
        self.stallVelocityThreshold = stallVelocityThreshold
        self.stallDistanceThreshold = stallDistanceThreshold
        self.stallVarianceMultiplier = stallVarianceMultiplier
        self.stallWidenFraction = stallWidenFraction
        self.adaptiveTemperature = adaptiveTemperature
        self.minCostScale = minCostScale
        self.normalizeRunningCostByHorizon = normalizeRunningCostByHorizon
    }
}
