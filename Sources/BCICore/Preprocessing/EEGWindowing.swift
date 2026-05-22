import Foundation

/// Windowing parameters used everywhere in the pipeline.
///
/// Default: 2-second window at 256 Hz with 50% overlap (stride = 1 s). That's
/// the same shape the mock classifier and the default Core ML input expect.
/// Change here, change in one place.
public struct EEGWindowingConfig: Sendable, Hashable {
    public let windowSeconds: Double
    public let strideSeconds: Double
    public let sampleRate: Double
    public let channelCount: Int

    public init(
        windowSeconds: Double = 2.0,
        strideSeconds: Double = 1.0,
        sampleRate: Double = 256.0,
        channelCount: Int = 4
    ) {
        precondition(windowSeconds > 0)
        precondition(strideSeconds > 0 && strideSeconds <= windowSeconds)
        precondition(sampleRate > 0)
        precondition(channelCount > 0)
        self.windowSeconds = windowSeconds
        self.strideSeconds = strideSeconds
        self.sampleRate = sampleRate
        self.channelCount = channelCount
    }

    public var samplesPerWindow: Int { Int((windowSeconds * sampleRate).rounded()) }
    public var samplesPerStride: Int { Int((strideSeconds * sampleRate).rounded()) }
}

/// Stateful windower: feed samples in, get windows out.
///
/// Channel-major output, ready for the bandpass filter and the Core ML
/// classifier. Validates channel count on every sample; on mismatch it raises
/// once and stops emitting until reset.
///
/// `EEGWindowing` is an `actor` because the EEG stream and the classifier
/// run in different concurrency domains, and the controller wants to push
/// samples + pull windows from both sides.
public actor EEGWindowing {

    public let config: EEGWindowingConfig

    private var pending: [[Float]]               // channel-major accumulator
    private var pendingSampleCount: Int = 0
    private var samplesSinceLastWindow: Int = 0
    private var nextSequence: UInt64 = 0
    private var lastTimestamp: TimeInterval = 0
    private var shapeMismatched: Bool = false

    public init(config: EEGWindowingConfig) {
        self.config = config
        self.pending = (0..<config.channelCount).map { _ in
            var arr: [Float] = []
            arr.reserveCapacity(config.samplesPerWindow * 2)
            return arr
        }
    }

    /// Feed one sample. Returns a window if a stride boundary has crossed
    /// AND we have at least `samplesPerWindow` accumulated; otherwise nil.
    ///
    /// Once we have any window, every subsequent call that crosses a stride
    /// boundary will emit a new one until samples are drained.
    public func ingest(_ sample: EEGSample) throws -> EEGWindow? {
        guard !shapeMismatched else { return nil }
        guard sample.channels.count == config.channelCount else {
            shapeMismatched = true
            throw BCIError.channelShapeMismatch(
                expected: config.channelCount,
                actual: sample.channels.count
            )
        }
        for (i, v) in sample.channels.enumerated() {
            pending[i].append(v)
        }
        pendingSampleCount += 1
        samplesSinceLastWindow += 1
        lastTimestamp = sample.timestamp

        if pendingSampleCount >= config.samplesPerWindow,
           samplesSinceLastWindow >= config.samplesPerStride {
            // Emit a window: copy out the most recent `samplesPerWindow`
            // per channel; trim oldest if we're holding more than 2× window.
            let w = config.samplesPerWindow
            var out: [[Float]] = []
            out.reserveCapacity(config.channelCount)
            for ch in 0..<config.channelCount {
                let start = pending[ch].count - w
                out.append(Array(pending[ch][start..<pending[ch].count]))
            }
            // Trim accumulator so it doesn't grow unbounded.
            let maxKeep = config.samplesPerWindow + config.samplesPerStride
            for ch in 0..<config.channelCount where pending[ch].count > maxKeep {
                pending[ch].removeFirst(pending[ch].count - maxKeep)
            }
            pendingSampleCount = pending[0].count
            samplesSinceLastWindow = 0
            let window = EEGWindow(
                samples: out,
                sampleRate: config.sampleRate,
                endTimestamp: lastTimestamp,
                sequence: nextSequence
            )
            nextSequence &+= 1
            return window
        }
        return nil
    }

    public func reset() {
        for i in pending.indices { pending[i].removeAll(keepingCapacity: true) }
        pendingSampleCount = 0
        samplesSinceLastWindow = 0
        nextSequence = 0
        shapeMismatched = false
    }

    public var sequenceCount: UInt64 { nextSequence }
}
