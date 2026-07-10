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
        /// Remote Muse over OSC (Mind Monitor, relayed over a private VPN
        /// such as Tailscale) — see `MindMonitorOSCStream`. The one source
        /// that touches the network at runtime; see
        /// `MuseBoardProfile.requiresNetwork`.
        case oscRemote
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
    /// Extra transport-specific detail for the privacy banner, e.g.
    /// `"UDP 5000 · utun3"` for `.oscRemote`. `Source` can't carry this
    /// itself — it's a `String`-raw-value `Codable` enum, and Swift doesn't
    /// allow associated values on individual cases of a raw-value enum.
    /// `nil` for sources with nothing more specific to show than
    /// `sourceProfile.displayName` already gives.
    public let transportDetail: String?

    public init(
        source: Source,
        sourceProfile: MuseBoardProfile,
        classifier: Classifier,
        predictor: Predictor,
        transportDetail: String? = nil
    ) {
        self.source = source
        self.sourceProfile = sourceProfile
        self.classifier = classifier
        self.predictor = predictor
        self.transportDetail = transportDetail
    }

    /// True if every stage is a real, hardware/model-backed component.
    public var isFullyLive: Bool {
        source == .brainflowMuse && classifier == .coreML && predictor == .mlx
    }

    /// Human-readable description of any substitutions for the privacy banner.
    public var substitutionSummary: String {
        var notes: [String] = []
        if source != .brainflowMuse {
            if let transportDetail {
                notes.append("EEG: \(sourceProfile.displayName) (\(transportDetail))")
            } else {
                notes.append("EEG: \(sourceProfile.displayName)")
            }
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
