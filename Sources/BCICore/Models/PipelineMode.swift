import Foundation

/// Snapshot of which substitutable component is *actually* live in each stage
/// of the pipeline, for use by the privacy indicator and metrics view.
///
/// Each field tells you "real or stand-in" — never null. The UI uses this to
/// render the privacy banner: green when every stage is real, amber when at
/// least one is a synthetic/mock/stub, red on hard errors.
///
/// `Acquisition` and `Transport` are deliberately separate facets rather than
/// one combined enum (the old `Source` — see git history around this file).
/// Today every acquisition path happens to pair with exactly one transport
/// (`.localMuse`+`.ble`, `.remotePhone`+`.oscUDP`, `.playback`+`.replay`,
/// `.synthetic`+`.none`), so decomposing them doesn't change any current
/// behavior — the payoff is for whatever comes next (e.g. a local Muse over
/// USB instead of BLE, or a relay transport that isn't OSC) not needing a
/// new combined case invented for it. `Classifier`/`Predictor` stay as
/// single facets — they don't have this "device vs. wire protocol" split to
/// decompose, and inventing hypothetical cases for them (a "disabled"
/// classifier, a "research" mode) isn't grounded in anything this codebase
/// actually does yet. Facets this project doesn't have a stable
/// implementation for yet (Embedding, Visualization) are deliberately not
/// here — see the semantic-embedding-backend scoping notes for why that's
/// staying a provider abstraction, not a pipeline-mode facet, until there's
/// a real implementation to model.
public struct PipelineMode: Sendable, Hashable {
    /// Which device the EEG signal originates from. Mutually exclusive with
    /// itself (one acquisition source is active at a time); composes with
    /// `Transport` for display, e.g. "Remote Phone · OSC/UDP".
    public enum Acquisition: String, Sendable, Codable {
        case localMuse
        case remotePhone
        case playback
        case synthetic

        public var displayName: String {
            switch self {
            case .localMuse:   return "Local Muse"
            case .remotePhone: return "Remote Phone"
            case .playback:    return "Playback"
            case .synthetic:   return "Synthetic"
            }
        }
    }

    /// How samples actually travel from the acquisition device to this
    /// process. See `Acquisition`'s doc comment for why this is split out.
    public enum Transport: String, Sendable, Codable {
        case ble
        case oscUDP
        case replay
        /// No wire protocol — samples are generated in-process
        /// (`SyntheticEEGStream`), so there's nothing to name here.
        case none

        public var displayName: String {
            switch self {
            case .ble:    return "BLE"
            case .oscUDP: return "OSC/UDP"
            case .replay: return "Replay"
            case .none:   return "—"
            }
        }
    }

    public enum Classifier: String, Sendable, Codable {
        case coreML
        case mock
    }
    public enum Predictor: String, Sendable, Codable {
        case mlx
        case stub
    }

    public let acquisition: Acquisition
    public let transport: Transport
    public let sourceProfile: MuseBoardProfile
    public let classifier: Classifier
    public let predictor: Predictor
    /// Extra transport-specific detail for the privacy banner, e.g.
    /// `"UDP 5000 · utun3"` for `.oscUDP`. Free-form rather than another
    /// enum case because it's inherently per-instance (a bound port number,
    /// a resolved interface name), not a fixed set of values. `nil` for
    /// transports with nothing more specific to show.
    public let transportDetail: String?

    public init(
        acquisition: Acquisition,
        transport: Transport,
        sourceProfile: MuseBoardProfile,
        classifier: Classifier,
        predictor: Predictor,
        transportDetail: String? = nil
    ) {
        self.acquisition = acquisition
        self.transport = transport
        self.sourceProfile = sourceProfile
        self.classifier = classifier
        self.predictor = predictor
        self.transportDetail = transportDetail
    }

    /// True if every stage is a real, hardware/model-backed component.
    public var isFullyLive: Bool {
        acquisition == .localMuse && transport == .ble && classifier == .coreML && predictor == .mlx
    }

    /// Short display strings for stacked-badge rendering, e.g.
    /// `["Remote Phone", "OSC/UDP"]` — `PrivacyIndicatorView` renders these
    /// as separate adjacent badges rather than one fused phrase. Omits
    /// `Transport.none` (nothing meaningful to show for synthetic).
    public var acquisitionBadges: [String] {
        transport == .none ? [acquisition.displayName] : [acquisition.displayName, transport.displayName]
    }

    /// Human-readable description of any substitutions for the privacy banner.
    public var substitutionSummary: String {
        var notes: [String] = []
        if acquisition != .localMuse {
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
