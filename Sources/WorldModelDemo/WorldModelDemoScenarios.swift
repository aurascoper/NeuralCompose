import Foundation

/// A small, fixed `(start, goal)` list for demo variety — reproducible
/// (no live randomness), not exhaustive. Includes the documented
/// corner-to-corner hard case from `WorldModel/README.md` so the demo can
/// show a known-hard trajectory struggling, not just easy wins.
public struct WorldModelDemoScenario: Sendable {
    public let name: String
    public let start: [Float]
    public let goal: [Float]

    public init(name: String, start: (Float, Float), goal: (Float, Float)) {
        self.name = name
        self.start = [start.0, start.1, 0, 0]
        self.goal = [goal.0, goal.1, 0, 0]
    }
}

public enum WorldModelDemoScenarios {
    /// Matches `WorldModel/sweep.py::HARD_CASES`'s `corner_pp_to_nn` case —
    /// the arena's diagonal maximum (distance 2.263), narrated throughout
    /// `WorldModel/README.md`'s "Fixing the receding-horizon stall" section.
    public static let cornerToCornerHardCase = WorldModelDemoScenario(
        name: "corner-to-corner (hard)", start: (0.8, 0.8), goal: (-0.8, -0.8)
    )

    public static let easyA = WorldModelDemoScenario(
        name: "easy A", start: (0.2, 0.3), goal: (-0.3, -0.1)
    )

    public static let easyB = WorldModelDemoScenario(
        name: "easy B", start: (-0.4, 0.5), goal: (0.5, -0.2)
    )

    public static let all: [WorldModelDemoScenario] = [easyA, easyB, cornerToCornerHardCase]
}
