import Foundation
import BCICore

/// One tick of everything the biofeedback egress is allowed to know:
/// per-channel band powers, per-channel health, the two Track A events,
/// and the IMU readings when the transport carries them.
///
/// This is the egress boundary. Nothing downstream of a `BiofeedbackFrame`
/// sees raw EEG samples, and the frame carries no identity, no text, no
/// transcript. What leaves the machine over OSC or MIDI is a function of
/// this struct and nothing else, which is what makes ADR-011's privacy
/// claim checkable: audit `MindMonitorMirror` and `FeatureMapper`, and
/// you have audited the egress.
///
/// Raw EEG re-broadcast (`/muse/eeg`) is the one deliberate exception and
/// is not reachable from a frame at all; see `MindMonitorMirror.rawEEG`.
public struct BiofeedbackFrame: Sendable, Hashable {

    /// Stream-relative seconds, same clock as `EEGSample.timestamp`.
    public let timestamp: TimeInterval

    /// Linear band power per channel, µV². Channels absent from the
    /// dictionary were not in the window.
    public let bandPowers: [EEGChannel: BandPowers]

    /// Health per channel. Channels absent from the dictionary are
    /// treated as `.unknown` by every consumer.
    public let health: [EEGChannel: ChannelHealthStatus]

    /// Track A blink event (single or double) present in this tick.
    public let blink: Bool

    /// Track A jaw-clench event present in this tick.
    public let jawClench: Bool

    /// Most recent accelerometer reading, if the transport carries one.
    public let accel: MovementSample?

    /// Most recent gyroscope reading, if the transport carries one.
    public let gyro: MovementSample?

    public init(
        timestamp: TimeInterval,
        bandPowers: [EEGChannel: BandPowers],
        health: [EEGChannel: ChannelHealthStatus],
        blink: Bool = false,
        jawClench: Bool = false,
        accel: MovementSample? = nil,
        gyro: MovementSample? = nil
    ) {
        self.timestamp = timestamp
        self.bandPowers = bandPowers
        self.health = health
        self.blink = blink
        self.jawClench = jawClench
        self.accel = accel
        self.gyro = gyro
    }

    /// Convenience constructor from the pipeline's own types. `intent` is
    /// the Track A classifier's decision for this window, if any; blinks
    /// and clenches are derived from it rather than re-detected here, so
    /// the egress never disagrees with the typing path about what
    /// happened.
    public init(
        window: EEGWindow,
        channels: [EEGChannel] = EEGChannel.allCases,
        health: [ChannelHealthState],
        intent: IntentClass? = nil,
        accel: MovementSample? = nil,
        gyro: MovementSample? = nil,
        estimator: BandPowerEstimator = BandPowerEstimator()
    ) {
        self.timestamp = window.endTimestamp
        self.bandPowers = estimator.powers(for: window, channels: channels)
        var healthByChannel: [EEGChannel: ChannelHealthStatus] = [:]
        for state in health { healthByChannel[state.channel] = state.status }
        self.health = healthByChannel
        switch intent {
        case .singleBlink, .doubleBlink:
            self.blink = true
            self.jawClench = false
        case .jawClench:
            self.blink = false
            self.jawClench = true
        default:
            self.blink = false
            self.jawClench = false
        }
        self.accel = accel
        self.gyro = gyro
    }

    /// Health lookup with the documented default.
    public func status(of channel: EEGChannel) -> ChannelHealthStatus {
        health[channel] ?? .unknown
    }

    /// Channels present in `bandPowers` whose health is `.healthy`, in
    /// `EEGChannel.allCases` order.
    public var healthyChannels: [EEGChannel] {
        EEGChannel.allCases.filter { bandPowers[$0] != nil && status(of: $0) == .healthy }
    }

    /// Channels present in `bandPowers`, in `EEGChannel.allCases` order.
    public var presentChannels: [EEGChannel] {
        EEGChannel.allCases.filter { bandPowers[$0] != nil }
    }
}
