import Foundation
import BCICore
import BCIEEG

/// Glue between the live pipeline and the egress. The app owns exactly one
/// of these when biofeedback is enabled (`AppContainer.biofeedback`) and
/// none when it is not; it is the only type that holds a `FeatureMapper`
/// and a `BiofeedbackSink` together.
///
/// Four inputs, each from the pipeline stage that already produces it, so
/// nothing is re-detected here:
///
/// - `ingest(window:)` takes the **raw** window from the windowing stage,
///   before `substituteBadChannels` runs. That matters: the cleaned window
///   has a lifted electrode overwritten with its contralateral partner,
///   which would hide the bad contact from both the horseshoe and the
///   mapper's `HealthPolicy`. Health is computed here from the raw window
///   unless the caller passes provider states.
/// - `note(intent:at:)` takes the Track A classifier's decision for the
///   window it just classified. Events (blink, jaw clench) are emitted on
///   that tick rather than attached to the next window, so a blink reaches
///   the DAW with classifier latency, not one stride of lag.
/// - `ingest(movement:)` caches the latest accelerometer and gyroscope
///   readings for the next window's frame.
/// - `ingest(sample:)` is the raw EEG re-broadcast. It is a no-op unless
///   `Options.includeRawEEG` is on, and it is the single call site of
///   `MindMonitorMirror.rawEEG(_:)` in the app's runtime path (ADR-011).
///
/// Mappings are split by feature: `.blink` and `.jawClench` mappings run on
/// intent ticks, everything else runs on window ticks. Each half has its
/// own `FeatureMapper`, so a window tick never double-emits band mappings
/// and an event tick never re-sends the mirror's band messages.
public actor BiofeedbackCoordinator {

    public struct Options: Sendable {
        /// Mind Monitor-compatible output; `nil` disables the mirror and
        /// leaves only the user's mappings.
        public var mirror: MindMonitorMirror?
        /// Raw `/muse/eeg` re-broadcast. Off by default; see ADR-011 §2.
        public var includeRawEEG: Bool
        public var thresholds: ChannelHealthThresholds
        public var estimator: BandPowerEstimator
        /// Row-to-channel assignment for incoming windows.
        public var channels: [EEGChannel]

        public init(
            mirror: MindMonitorMirror? = MindMonitorMirror(),
            includeRawEEG: Bool = false,
            thresholds: ChannelHealthThresholds = .default,
            estimator: BandPowerEstimator = BandPowerEstimator(),
            channels: [EEGChannel] = EEGChannel.allCases
        ) {
            self.mirror = mirror
            self.includeRawEEG = includeRawEEG
            self.thresholds = thresholds
            self.estimator = estimator
            self.channels = channels
        }
    }

    public let options: Options
    private let sink: any BiofeedbackSink
    private var continuous: FeatureMapper
    private var events: FeatureMapper
    private var latestAccel: MovementSample?
    private var latestGyro: MovementSample?
    private var lastFrame: BiofeedbackFrame?

    /// Windows ingested so far (diagnostics and tests).
    public private(set) var windowCount = 0
    /// Intent ticks that carried a blink or clench (diagnostics and tests).
    public private(set) var eventCount = 0

    public init(
        sink: any BiofeedbackSink,
        mappings: [BiofeedbackMapping] = [],
        options: Options = Options()
    ) {
        self.sink = sink
        self.options = options
        let split = BiofeedbackCoordinator.split(mappings)
        self.continuous = FeatureMapper(mappings: split.continuous)
        self.events = FeatureMapper(mappings: split.events)
    }

    /// Whether `ingest(sample:)` does anything. Read without an actor hop
    /// so the 256 Hz sample loop can skip the call entirely when off.
    public nonisolated var includesRawEEG: Bool {
        options.includeRawEEG
    }

    /// All mappings, continuous first then event mappings.
    public var mappings: [BiofeedbackMapping] {
        continuous.mappings + events.mappings
    }

    /// Replace the mapping set; smoother state survives for surviving ids
    /// (see `FeatureMapper.replaceMappings`).
    public func replaceMappings(_ mappings: [BiofeedbackMapping]) {
        let split = BiofeedbackCoordinator.split(mappings)
        continuous.replaceMappings(split.continuous)
        events.replaceMappings(split.events)
    }

    /// Window tick. `health` overrides the raw-window estimate when the
    /// caller has provider states (which can carry `.stale`); otherwise
    /// per-channel demeaned RMS against `options.thresholds`.
    public func ingest(window: EEGWindow, health: [ChannelHealthState]? = nil) async {
        let states = health ?? BiofeedbackCoordinator.channelHealth(
            for: window, channels: options.channels, thresholds: options.thresholds
        )
        let frame = BiofeedbackFrame(
            window: window,
            channels: options.channels,
            health: states,
            intent: nil,
            accel: latestAccel,
            gyro: latestGyro,
            estimator: options.estimator
        )
        lastFrame = frame
        windowCount += 1

        var outputs: [BiofeedbackOutput] = []
        if let mirror = options.mirror {
            outputs += mirror.messages(for: frame).map { .osc($0) }
        }
        outputs += continuous.step(frame)
        if !outputs.isEmpty {
            await sink.emit(outputs)
        }
    }

    /// Classifier tick. Builds an event frame on top of the last window's
    /// band powers and health, runs the event mappings and, when the mirror
    /// is on, the two Mind Monitor event messages. Called for every
    /// classified window, including `.rest`, so open note gates close.
    public func note(intent: IntentClass, at timestamp: TimeInterval) async {
        let blink: Bool
        let jawClench: Bool
        switch intent {
        case .singleBlink, .doubleBlink:
            blink = true
            jawClench = false
        case .jawClench:
            blink = false
            jawClench = true
        case .rest, .select:
            blink = false
            jawClench = false
        }

        let frame = BiofeedbackFrame(
            timestamp: timestamp,
            bandPowers: lastFrame?.bandPowers ?? [:],
            health: lastFrame?.health ?? [:],
            blink: blink,
            jawClench: jawClench,
            accel: latestAccel,
            gyro: latestGyro
        )
        if blink || jawClench { eventCount += 1 }

        var outputs: [BiofeedbackOutput] = []
        if options.mirror != nil {
            outputs += MindMonitorMirror.eventMessages(blink: blink, jawClench: jawClench).map { .osc($0) }
        }
        outputs += events.step(frame)
        if !outputs.isEmpty {
            await sink.emit(outputs)
        }
    }

    /// IMU tick. Cached; forwarded with the next window frame.
    public func ingest(movement: MovementSample) {
        switch movement.kind {
        case .accel: latestAccel = movement
        case .gyro:  latestGyro = movement
        }
    }

    /// Raw EEG re-broadcast. No-op unless `options.includeRawEEG`.
    public func ingest(sample: EEGSample) async {
        guard options.includeRawEEG else { return }
        await sink.emit([.osc(MindMonitorMirror.rawEEG(sample))])
    }

    /// Per-channel health from a raw window: demeaned RMS in Double against
    /// `thresholds`. A channel with any non-finite sample reads `.unknown`
    /// with an RMS of 0 rather than poisoning the estimate. Mirrors the
    /// arithmetic of `AppViewModel.signalQuality(of:)` but keeps the
    /// per-channel result instead of bucketing to one quality.
    public static func channelHealth(
        for window: EEGWindow,
        channels: [EEGChannel] = EEGChannel.allCases,
        thresholds: ChannelHealthThresholds = .default
    ) -> [ChannelHealthState] {
        var states: [ChannelHealthState] = []
        for (index, channel) in channels.enumerated() where index < window.samples.count {
            let samples = window.samples[index]
            let n = samples.count
            guard n > 0, samples.allSatisfy(\.isFinite) else {
                states.append(ChannelHealthState(channel: channel, status: .unknown, rms: 0, samples: n, timestamp: window.endTimestamp))
                continue
            }
            var mean = 0.0
            for v in samples { mean += Double(v) }
            mean /= Double(n)
            var sumSq = 0.0
            for v in samples {
                let d = Double(v) - mean
                sumSq += d * d
            }
            let rms = Float((sumSq / Double(n)).squareRoot())
            states.append(ChannelHealthState(
                channel: channel,
                status: thresholds.status(forRMS: rms, samples: n),
                rms: rms,
                samples: n,
                timestamp: window.endTimestamp
            ))
        }
        return states
    }

    private static func split(_ mappings: [BiofeedbackMapping]) -> (continuous: [BiofeedbackMapping], events: [BiofeedbackMapping]) {
        var continuous: [BiofeedbackMapping] = []
        var events: [BiofeedbackMapping] = []
        for mapping in mappings {
            switch mapping.feature {
            case .blink, .jawClench: events.append(mapping)
            default: continuous.append(mapping)
            }
        }
        return (continuous, events)
    }
}
