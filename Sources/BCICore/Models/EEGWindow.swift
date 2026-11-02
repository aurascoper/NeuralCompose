import Foundation

/// A fixed-length, multi-channel window of EEG samples ready for classification.
///
/// Layout is channel-major (`samples[channel][sample]`) which matches what the
/// Core ML model and the feature extractor both want, and avoids a transpose at
/// inference time.
public struct EEGWindow: Sendable {
    /// `samples[channel][sample]` - channel-major.
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

    /// Contralateral partner index mapping for the 4-channel Muse montage
    /// (`[TP9, AF7, AF8, TP10]` -> `0 <-> 3`, `1 <-> 2`), mirroring
    /// `CHANNEL_PAIRS` in `Scripts/eeg_channel_quality.py`.
    private static let museContralateralPartnerIndices = [3, 2, 1, 0]

    /// Returns a copy of this window where any `.dead` or `.saturated` channel
    /// on a 4-channel Muse montage (`TP9 <-> TP10`, `AF7 <-> AF8`) whose
    /// contralateral partner is `.healthy` is replaced with its demeaned
    /// healthy partner. If both channels in a pair are bad, or the window does
    /// not have 4 channels, affected channels are left untouched.
    public func substitutingBadChannels(
        thresholds: ChannelHealthThresholds = .default
    ) -> EEGWindow {
        guard samples.count == 4 else { return self }

        var statuses: [ChannelHealthStatus] = []
        statuses.reserveCapacity(4)
        var demeanedChannels: [[Float]] = []
        demeanedChannels.reserveCapacity(4)

        for row in samples {
            guard !row.isEmpty else {
                statuses.append(.unknown)
                demeanedChannels.append([])
                continue
            }
            var sum: Double = 0
            var hasNonFinite = false
            for v in row {
                if !v.isFinite {
                    hasNonFinite = true
                    break
                }
                sum += Double(v)
            }
            if hasNonFinite {
                statuses.append(.saturated)
                demeanedChannels.append(row)
                continue
            }
            let n = Double(row.count)
            let mean = sum / n
            var sumSq: Double = 0
            var centered: [Float] = []
            centered.reserveCapacity(row.count)
            for v in row {
                let ac = Double(v) - mean
                sumSq += ac * ac
                centered.append(Float(ac))
            }
            let rms = Float((sumSq / n).squareRoot())
            statuses.append(thresholds.status(forRMS: rms, samples: row.count))
            demeanedChannels.append(centered)
        }

        var outSamples = samples
        var didSubstitute = false
        for ch in 0..<4 {
            guard statuses[ch] == .dead || statuses[ch] == .saturated else { continue }
            let partner = Self.museContralateralPartnerIndices[ch]
            guard statuses[partner] == .healthy,
                  demeanedChannels[partner].count == samples[ch].count else { continue }
            outSamples[ch] = demeanedChannels[partner]
            didSubstitute = true
        }

        guard didSubstitute else { return self }
        return EEGWindow(
            samples: outSamples,
            sampleRate: sampleRate,
            endTimestamp: endTimestamp,
            sequence: sequence
        )
    }
}
