import Foundation

/// Stable identifier for one electrode on a Muse / Muse-S / Muse-2 board.
/// Synthetic and playback profiles resolve to a synthesized layout based
/// on the actual sample's channel count.
public enum EEGChannel: String, Sendable, Hashable, CaseIterable, Codable {
    case tp9
    case af7
    case af8
    case tp10

    /// Short uppercase label, matching the convention used by the
    /// existing `MuseBoardProfile.channelLabels`.
    public var label: String {
        switch self {
        case .tp9:  return "TP9"
        case .af7:  return "AF7"
        case .af8:  return "AF8"
        case .tp10: return "TP10"
        }
    }
}

/// Coarse signal-quality bucket for a single channel. Derived from
/// per-channel RMS over a recent window of EEG samples; see
/// `ChannelHealthThresholds` for the current engineering heuristic.
public enum ChannelHealthStatus: String, Sendable, Hashable, Codable {
    /// Not enough samples yet to form a stable estimate.
    case unknown
    /// RMS in the configured healthy range.
    case healthy
    /// RMS above the saturated threshold; typically muscle / motion
    /// contamination or 50/60 Hz interference, sometimes an analog
    /// front-end fault.
    case saturated
    /// RMS below the dead threshold; typically an electrode lifted off
    /// the scalp or a dry pad.
    case dead
}

/// One channel's health snapshot, as produced by a
/// `ChannelHealthProviding` implementation.
public struct ChannelHealthState: Sendable, Hashable {
    public let channel: EEGChannel
    public let status: ChannelHealthStatus
    /// Root-mean-square amplitude over the most recent
    /// `samples`-many samples, in microvolts.
    public let rms: Float
    /// Number of samples that contributed to `rms`.
    public let samples: Int
    /// Wall-clock time of the most recent sample that contributed to
    /// this estimate, in seconds since the Unix epoch. Matches the
    /// `timestamp` field on `EEGSample` and on `ImaginedTrialEvent`,
    /// so a downstream consumer can align channel health with
    /// protocol events without a clock translation.
    public let timestamp: TimeInterval

    public init(
        channel: EEGChannel,
        status: ChannelHealthStatus,
        rms: Float,
        samples: Int,
        timestamp: TimeInterval
    ) {
        self.channel = channel
        self.status = status
        self.rms = rms
        self.samples = samples
        self.timestamp = timestamp
    }
}
