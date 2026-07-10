import Foundation
import BCICore

/// A `ChannelHealthProviding` that subscribes to an existing
/// `AsyncStream<EEGSample>` and computes per-channel RMS from a
/// rolling window of recent samples.
///
/// The provider does **not** call `EEGStreaming.start()`. It is a
/// read-only consumer of the stream that `AppViewModel` already
/// owns (see `AppViewModel.liveSampleStream()` for the single-owner
/// invariant). Multiple providers can be constructed from the same
/// `AsyncStream` because `AsyncStream` is a single-iteration value
/// type — the call site should `makeSampleStream()` once and pass
/// the resulting `AsyncStream` to each consumer.
///
/// **Future Architecture.** The 4-second per-channel ring and the
/// drain task are intentional duplicates of the work the
/// `EEGScalpPlotterView` does. They are a transitional design:
/// today the codebase has no canonical owner of the live EEG
/// stream's analysis buffer, so each visualization consumer keeps
/// its own small ring. If a `SignalAnalysisBuffer` is introduced
/// later, this provider should migrate to read from it and the
/// duplicated buffering here can be removed.
public final class EEGChannelHealthProvider: ChannelHealthProviding, @unchecked Sendable {

    /// Width of the per-channel sample ring, in seconds. At the
    /// default 256 Hz Muse sample rate this is 1024 floats per
    /// channel — plenty of headroom for a 1-second RMS window plus
    /// smoothing. 4 s is chosen so the same ring can answer
    /// `windowSeconds: 2.0` queries with the most recent second of
    /// context available for diagnostic timestamps.
    public let ringSeconds: Double

    /// Sample rate used to size the per-channel ring. Captured at
    /// init so the ring capacity is stable for the lifetime of the
    /// provider. If the live stream changes sample rate at runtime
    /// (it does not today), the provider should be reconstructed.
    public let sampleRate: Double

    private let thresholds: ChannelHealthThresholds
    private let channelCount: Int
    private let channelLabels: [String]
    private let storage: Storage
    private let drainTask: Task<Void, Never>?

    /// - Parameters:
    ///   - stream: A live `AsyncStream<EEGSample>`. The provider
    ///     spawns a task that drains the stream into its internal
    ///     ring until the stream finishes or the provider is
    ///     deallocated. If `nil`, the provider returns `.unknown`
    ///     for every channel until a stream is supplied — there is
    ///     no implicit fallback to `EEGStreaming.start()`.
    ///   - channelCount: Number of channels expected per sample.
    ///   - channelLabels: Display labels for each channel, in
    ///     sample-index order. Used to map `Int`-indexed storage
    ///     back to a labeled `EEGChannel` for the result.
    ///   - sampleRate: Sample rate in Hz, used to size the ring.
    ///   - ringSeconds: Width of the ring in seconds. Default 4.
    ///   - thresholds: Initial engineering thresholds. Default
    ///     `.default`.
    public init(
        stream: AsyncStream<EEGSample>? = nil,
        channelCount: Int = 4,
        channelLabels: [String] = ["TP9", "AF7", "AF8", "TP10"],
        sampleRate: Double = 256.0,
        ringSeconds: Double = 4.0,
        thresholds: ChannelHealthThresholds = .default
    ) {
        precondition(channelCount > 0, "channelCount must be positive")
        precondition(ringSeconds > 0, "ringSeconds must be positive")
        self.ringSeconds = ringSeconds
        self.sampleRate = sampleRate
        self.thresholds = thresholds
        self.channelCount = channelCount
        self.channelLabels = channelLabels
        let capacity = max(1, Int(ringSeconds * sampleRate))
        self.storage = Storage(channelCount: channelCount, capacity: capacity)
        if let stream = stream {
            self.drainTask = Task { [weak storage] in
                for await sample in stream {
                    storage?.ingest(sample)
                }
            }
        } else {
            self.drainTask = nil
        }
    }

    deinit {
        drainTask?.cancel()
    }

    public func currentChannelHealth(windowSeconds: Double) async -> [ChannelHealthState] {
        let windowSamples = max(1, Int((windowSeconds > 0 ? windowSeconds : 1.0) * sampleRate))
        return storage.snapshot(windowSamples: windowSamples, thresholds: thresholds, channelLabels: channelLabels)
    }

    // MARK: - Storage

    /// Owns the per-channel ring buffers and produces snapshots.
    /// Marked `@unchecked Sendable` because every mutation goes
    /// through a serial `NSLock` and the data is value-typed.
    private final class Storage: @unchecked Sendable {
        private let channelCount: Int
        private let capacity: Int
        /// Per-channel ring buffer. Flattened into `[Float]` per
        /// channel to match the `EEGScalpPlotterView` pattern.
        private var buffers: [[Float]]
        private var writeIndex: Int = 0
        /// Number of samples that have ever been appended; used to
        /// distinguish a ring full of stale zeros from a fresh ring.
        private var totalAppends: Int = 0
        /// Timestamp of the most recent sample ingested.
        private var lastTimestamp: TimeInterval = 0
        private let lock = NSLock()

        init(channelCount: Int, capacity: Int) {
            self.channelCount = channelCount
            self.capacity = capacity
            self.buffers = Array(repeating: [Float](repeating: 0, count: capacity), count: channelCount)
        }

        func ingest(_ sample: EEGSample) {
            lock.lock()
            defer { lock.unlock() }
            for ch in 0..<min(channelCount, sample.channels.count) {
                buffers[ch][writeIndex] = sample.channels[ch]
            }
            writeIndex = (writeIndex &+ 1) % capacity
            totalAppends &+= 1
            lastTimestamp = sample.timestamp
        }

        /// Build one `ChannelHealthState` per channel from the most
        /// recent `windowSamples` samples. The window is taken from
        /// the most recent slice of the ring, walking backwards from
        /// `writeIndex - 1`.
        func snapshot(
            windowSamples: Int,
            thresholds: ChannelHealthThresholds,
            channelLabels: [String]
        ) -> [ChannelHealthState] {
            lock.lock()
            let count = min(totalAppends, capacity)
            let window = min(windowSamples, count)
            let perChannel: [(rms: Float, samples: Int)] = (0..<channelCount).map { ch in
                guard window > 0 else { return (0, 0) }
                var sumSq: Float = 0
                for offset in 0..<window {
                    // Most recent first: writeIndex - 1 - offset.
                    let idx = (writeIndex &- 1 &- offset &+ capacity) % capacity
                    let v = buffers[ch][idx]
                    sumSq += v * v
                }
                let mean = sumSq / Float(window)
                return (sqrtf(mean), window)
            }
            let ts = lastTimestamp
            lock.unlock()

            return (0..<channelCount).map { ch in
                let (rms, samples) = perChannel[ch]
                let status = thresholds.status(forRMS: rms, samples: samples)
                let label = ch < channelLabels.count ? channelLabels[ch] : "ch\(ch)"
                return ChannelHealthState(
                    channel: channelForLabel(label),
                    status: status,
                    rms: rms,
                    samples: samples,
                    timestamp: ts
                )
            }
        }

        /// Map a label string back to the `EEGChannel` enum when
        /// possible. Falls back to `.tp9` for unrecognized labels
        /// (e.g. `ch0` from the synthetic stream); the badge UI
        /// can still render the label, but the typed identifier
        /// is the best-effort mapping.
        private func channelForLabel(_ label: String) -> EEGChannel {
            switch label.uppercased() {
            case "TP9":  return .tp9
            case "AF7":  return .af7
            case "AF8":  return .af8
            case "TP10": return .tp10
            default:     return .tp9
            }
        }
    }
}
