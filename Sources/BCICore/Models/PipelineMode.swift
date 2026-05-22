import Foundation

/// Snapshot of which substitutable component is *actually* live in each stage
/// of the pipeline, for use by the privacy indicator and metrics view.
///
/// Each field tells you "real or stand-in" — never null. The UI uses this to
/// render the privacy banner: green when every stage is real, amber when at
/// least one is a synthetic/mock/stub, red on hard errors.
public struct PipelineMode: Sendable, Hashable {
    public enum Source: String, Sendable, Codable {
        case brainflowMuse
        case brainflowSynthetic
        case synthetic
        case playback
    }
    public enum Classifier: String, Sendable, Codable {
        case coreML
        case mock
    }
    public enum Predictor: String, Sendable, Codable {
        case mlx
        case stub
    }

    public let source: Source
    public let sourceProfile: MuseBoardProfile
    public let classifier: Classifier
    public let predictor: Predictor

    public init(
        source: Source,
        sourceProfile: MuseBoardProfile,
        classifier: Classifier,
        predictor: Predictor
    ) {
        self.source = source
        self.sourceProfile = sourceProfile
        self.classifier = classifier
        self.predictor = predictor
    }

    /// True if every stage is a real, hardware/model-backed component.
    public var isFullyLive: Bool {
        source == .brainflowMuse && classifier == .coreML && predictor == .mlx
    }

    /// Human-readable description of any substitutions for the privacy banner.
    public var substitutionSummary: String {
        var notes: [String] = []
        if source != .brainflowMuse {
            notes.append("EEG: \(sourceProfile.displayName)")
        }
        if classifier == .mock {
            notes.append("Classifier: mock")
        }
        if predictor == .stub {
            notes.append("LLM: stub")
        }
        if notes.isEmpty { return "All systems live" }
        return notes.joined(separator: " · ")
    }
}
