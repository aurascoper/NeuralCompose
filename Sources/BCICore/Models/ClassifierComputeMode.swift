import Foundation

/// Run-time compute placement for the Core ML intent classifier.
///
/// `cpuAndNeuralEngine` is the *default* and the right choice on Apple
/// Silicon: it explicitly avoids the GPU, leaving the GPU 100% free for MLX
/// to drive next-word prediction without contention.
///
/// `all` lets Core ML schedule freely; only use it if you've profiled and
/// confirmed no GPU contention with your MLX model.
///
/// `cpuOnly` is a debug fallback — useful when you suspect ANE-routed quirks
/// or want deterministic CPU-only timing.
///
/// Note: there is no `.neuralEngineOnly` mode in `MLComputeUnits`. Don't
/// introduce one here either.
public enum ClassifierComputeMode: String, CaseIterable, Sendable, Codable {
    case cpuAndNeuralEngine
    case all
    case cpuOnly

    public var displayName: String {
        switch self {
        case .cpuAndNeuralEngine: return "CPU + ANE (recommended)"
        case .all:                return "All (CPU + GPU + ANE)"
        case .cpuOnly:            return "CPU only (debug)"
        }
    }

    public var rationale: String {
        switch self {
        case .cpuAndNeuralEngine:
            return "Keeps the GPU free for MLX, classifier runs on ANE."
        case .all:
            return "May contend with MLX for the GPU."
        case .cpuOnly:
            return "Slow but deterministic. Use only for debugging."
        }
    }
}
