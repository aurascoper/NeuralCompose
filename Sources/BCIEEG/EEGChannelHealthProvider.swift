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

    /// If no sample has been ingested for longer than this many real
    /// (wall-clock) seconds, every channel's status is reported as
    /// `.stale` regardless of what the amplitude-derived bucket would
    /// otherwise say. See `ChannelHealthStatus.stale`'s doc comment
    /// for why this exists — without it, a stalled transport leaves
    /// the badge UI frozen on a last-known reading with no visual
    /// distinction from a genuinely current one.
    ///
    /// Deliberately shorter than `BrainFlowService`/
    /// `MindMonitorOSCStream`'s own `staleTimeoutSec` (5s default,
    /// used to decide when to actually retry the transport). This
    /// value only gates a *display* signal — "is this reading
    /// current" — so it can and should fire well before the
    /// transport-level watchdog forces a retry, giving the user an
    /// earlier heads-up that something's off.
    private let staleTimeoutSec: Double

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
    ///   - staleTimeoutSec: See the property's doc comment. Default 2.
    public init(
        stream: AsyncStream<EEGSample>? = nil,
        channelCount: Int = 4,
        channelLabels: [String] = ["TP9", "AF7", "AF8", "TP10"],
        sampleRate: Double = 256.0,
        ringSeconds: Double = 4.0,
        thresholds: ChannelHealthThresholds = .default,
        staleTimeoutSec: Double = 2.0
    ) {
        precondition(channelCount > 0, "channelCount must be positive")
        precondition(ringSeconds > 0, "ringSeconds must be positive")
        self.ringSeconds = ringSeconds
        self.sampleRate = sampleRate
        self.thresholds = thresholds
        self.channelCount = channelCount
        self.channelLabels = channelLabels
        self.staleTimeoutSec = staleTimeoutSec
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
        let states = storage.snapshot(windowSamples: windowSamples, thresholds: thresholds, channelLabels: channelLabels)

        // Staleness is a property of the *stream*, not any one
        // channel — if the transport stopped delivering samples,
        // every channel is equally stale. `secondsSinceLastIngest`
        // is `nil` before the first sample ever arrives, in which
        // case the amplitude-derived `.unknown` bucket already
        // communicates "no data yet" and staleness would be
        // redundant (and wrong — there's nothing stale about a
        // provider that was only just constructed).
        guard let staleness = storage.secondsSinceLastIngest(now: Date()),
              staleness > staleTimeoutSec
        else { return states }

        return states.map { state in
            ChannelHealthState(
                channel: state.channel, status: .stale,
                rms: state.rms, samples: state.samples, timestamp: state.timestamp
            )
        }
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
        /// Timestamp of the most recent sample ingested. Stream-relative
        /// (see `EEGSample.timestamp`), so it cannot be compared against
        /// `Date()` to detect staleness — `lastIngestWallClock` below is
        /// the real clock reading used for that.
        private var lastTimestamp: TimeInterval = 0
        /// Real wall-clock time `ingest(_:)` was last called. Distinct
        /// from `lastTimestamp` on purpose — see that property's doc
        /// comment.
        private var lastIngestWallClock: Date?
        private let lock = NSLock()

        init(channelCount: Int, capacity: Int) {
            self.channelCount = channelCount
            self.capacity = capacity
            self.buffers = Array(repeating: [Float](repeating: 0, count: capacity), count: channelCount)
        }

        /// Real seconds elapsed since the last `ingest(_:)` call, or
        /// `nil` if nothing has ever been ingested.
        func secondsSinceLastIngest(now: Date) -> TimeInterval? {
            lock.lock()
            defer { lock.unlock() }
            guard let lastIngestWallClock else { return nil }
            return now.timeIntervalSince(lastIngestWallClock)
        }

        func ingest(_ sample: EEGSample) {
            lock.lock()
            defer { lock.unlock() }
            for ch in 0..<min(channelCount, sample.channels.count) {
                buffers[ch][writeIndex] = sample.channels[ch]
            }
            writeIndex = (writeIndex &+ 1) % capacity
            totalAppends &+= 1
            lastIngestWallClock = Date()
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
                // First pass: per-channel DC baseline over the window. Real EEG
                // (Muse ~800µV offset over OSC) would otherwise dominate the RMS
                // and peg every channel to `.saturated`; RMS of the demeaned (AC)
                // signal is the quality metric we actually want. Synthetic data
                // is ~0-mean, so this is a no-op there.
                var dc: Float = 0
                for offset in 0..<window {
                    let idx = (writeIndex &- 1 &- offset &+ capacity) % capacity
                    dc += buffers[ch][idx]
                }
                dc /= Float(window)
                var sumSq: Float = 0
                for offset in 0..<window {
                    // Most recent first: writeIndex - 1 - offset.
                    let idx = (writeIndex &- 1 &- offset &+ capacity) % capacity
                    let v = buffers[ch][idx] - dc
                    sumSq += v * v
                }
                let meanSquare = sumSq / Float(window)
                return (sqrtf(meanSquare), window)
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
