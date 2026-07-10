import Foundation

/// Classifies a per-channel RMS measurement into a
/// `ChannelHealthStatus`. The default values are **engineering
/// heuristics** derived for the Muse S validation subject on
/// 2026-07-10 and are NOT physiologically validated cutoffs. They
/// are intended to be tuned as more recordings become available.
///
/// **Future Architecture.** This struct is intentionally pure: it
/// has no actor isolation, no I/O, and no dependencies. A future
/// revision may add learned thresholds, per-subject calibration, or
/// frequency-band-conditional rules. All such changes should remain
/// pure functions so the protocol and the tests do not have to
/// change.
public struct ChannelHealthThresholds: Sendable, Equatable {

    /// RMS below this value is classified as `.dead`. The default
    /// is an engineering heuristic; the units are microvolts.
    public let deadRMS: Float

    /// RMS above this value is classified as `.saturated`. The
    /// default is an engineering heuristic; the units are
    /// microvolts.
    public let saturatedRMS: Float

    /// Below this many samples, the classifier returns `.unknown`
    /// regardless of the RMS value, because very short windows are
    /// dominated by a single oscillation and do not represent the
    /// long-run amplitude of the channel.
    public let minimumSamples: Int

    public init(deadRMS: Float, saturatedRMS: Float, minimumSamples: Int = 32) {
        precondition(deadRMS >= 0, "deadRMS must be non-negative")
        precondition(saturatedRMS > deadRMS, "saturatedRMS must exceed deadRMS")
        precondition(minimumSamples > 0, "minimumSamples must be positive")
        self.deadRMS = deadRMS
        self.saturatedRMS = saturatedRMS
        self.minimumSamples = minimumSamples
    }

    /// Initial engineering thresholds derived for the Muse S
    /// validation subject. Subject to calibration and empirical
    /// refinement.
    ///
    /// The numbers (2 µV dead, 200 µV saturated) are consistent with
    /// the per-channel RMS bucket used by
    /// `AppViewModel.signalQuality(of:)` for the in-app
    /// healthy / poor / lost aggregate, but extend it to per-channel
    /// status with a saturated bucket.
    public static let `default` = ChannelHealthThresholds(
        deadRMS: 2,
        saturatedRMS: 200,
        minimumSamples: 32
    )

    /// Classify a per-channel RMS measurement.
    ///
    /// - Parameters:
    ///   - rms: Root-mean-square amplitude in microvolts over the
    ///     most recent `samples` samples.
    ///   - samples: Number of samples that contributed to `rms`.
    /// - Returns: One of `.unknown`, `.healthy`, `.saturated`,
    ///   `.dead`. The `.unknown` case is returned when `samples` is
    ///   below `minimumSamples`; the other three are returned in
    ///   increasing RMS order (dead → healthy → saturated).
    public func status(forRMS rms: Float, samples: Int) -> ChannelHealthStatus {
        guard samples >= minimumSamples else { return .unknown }
        if rms > saturatedRMS { return .saturated }
        if rms < deadRMS { return .dead }
        return .healthy
    }
}
