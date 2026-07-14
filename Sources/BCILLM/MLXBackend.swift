import Foundation

/// Which MLX model family to load. `LLMModelFactory.shared.loadContainer`
/// (vendored `mlx-swift-examples`) already dispatches Qwen vs. Gemma
/// automatically by reading the model's own `config.json` — this enum
/// only carries the two pieces of metadata that aren't in that file:
/// where to find the model on disk by default, and which
/// `GenerationConfiguration` (EOS tokens, repetition penalty) applies.
public enum MLXBackend: String, Sendable, CaseIterable {
    case qwen
    case gemma

    /// Leaf directory name under `Models/` — a name, not a path.
    /// `PredictorFactory.resolveDefaultDirectory` is the single place that
    /// resolves it against the `Models/` base directory.
    public var defaultModelName: String {
        switch self {
        case .qwen: return "Qwen2.5-0.5B-Instruct-4bit"
        case .gemma: return "gemma-3n-E2B-it-lm-4bit"
        }
    }

    public var configuration: GenerationConfiguration {
        switch self {
        case .qwen: return .qwen
        case .gemma: return .gemma
        }
    }
}
