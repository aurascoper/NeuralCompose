import Foundation

/// A fixed-length, multi-channel window of EEG samples ready for classification.
///
/// Layout is channel-major (`samples[channel][sample]`) which matches what the
/// Core ML model and the feature extractor both want, and avoids a transpose at
/// inference time.
public struct EEGWindow: Sendable {
    /// `samples[channel][sample]` — channel-major.
    public let samples: [[Float]]

    /// Sample rate of the underlying stream, Hz.
    public let sampleRate: Double

    /// Wall-clock time at which the window's *last* sample was acquired.
    public let endTimestamp: TimeInterval

    /// Monotonically increasing window index from the windowing stage. Lets the
    /// classifier reason about ordering even after async hops.
    public let sequence: UInt64

    public init(
        samples: [[Float]],
        sampleRate: Double,
        endTimestamp: TimeInterval,
        sequence: UInt64
    ) {
        self.samples = samples
        self.sampleRate = sampleRate
        self.endTimestamp = endTimestamp
        self.sequence = sequence
    }

    public var channelCount: Int { samples.count }
    public var sampleCount: Int  { samples.first?.count ?? 0 }
    public var durationSeconds: TimeInterval { Double(sampleCount) / sampleRate }
}
