import Foundation
import BCICore
import BCIEEG

/// Emits a `BiofeedbackFrame` in Mind Monitor's OSC address scheme, so a
/// consumer written against Mind Monitor (the Muse Port Max for Live
/// device, TouchDesigner and SuperCollider patches, Bitwig's OSC input)
/// can be pointed at NeuralCompose instead and work unchanged.
///
/// What is mirrored, per the Mind Monitor FAQ table:
///
/// | Address                            | Payload                                   |
/// |------------------------------------|-------------------------------------------|
/// | `/muse/elements/<band>_absolute`   | 1 float (average) or 4 floats, Bels       |
/// | `/muse/elements/horseshoe`         | 4 floats, 1 good / 2 medium / 4 bad       |
/// | `/muse/elements/blink`             | 1 int, sent only on a blink tick          |
/// | `/muse/elements/jaw_clench`        | 1 int, sent only on a clench tick         |
/// | `/muse/acc`, `/muse/gyro`          | 3 floats (g, deg/s) when the frame has them |
///
/// Not mirrored: `/muse/batt` (no battery data reaches the frame) and
/// `/muse/elements/touching_forehead` (Muse's on-head detector is not
/// exposed by the pipeline; the horseshoe carries contact quality).
///
/// Raw EEG (`/muse/eeg`) is deliberately not derivable from a frame. The
/// static `rawEEG(_:)` helper exists for the explicit raw re-broadcast
/// toggle ADR-011 allows, and takes an `EEGSample`, so the call site that
/// forwards raw samples is greppable and distinct from everything else
/// this type does.
///
/// Compatibility values are **not** health gated: a Mind Monitor
/// consumer expects band powers alongside a horseshoe and decides for
/// itself. The one concession is `averageOverHealthyChannelsOnly`, which
/// changes what the single averaged value averages over; per-channel
/// output is always all four channels so positions line up.
public struct MindMonitorMirror: Sendable, Hashable, Codable {

    /// Send 4 floats per band (Mind Monitor's "separate values for each
    /// sensor" setting) instead of its default single average.
    public var perChannel: Bool

    /// When averaging, use only healthy channels if any exist.
    public var averageOverHealthyChannelsOnly: Bool

    /// Channel order for 4-float payloads. Mind Monitor's order is
    /// TP9, AF7, AF8, TP10, which is `EEGChannel.allCases`.
    public static let channelOrder: [EEGChannel] = EEGChannel.allCases

    public init(perChannel: Bool = false, averageOverHealthyChannelsOnly: Bool = true) {
        self.perChannel = perChannel
        self.averageOverHealthyChannelsOnly = averageOverHealthyChannelsOnly
    }

    public static let horseshoeAddress = "/muse/elements/horseshoe"
    public static let blinkAddress = "/muse/elements/blink"
    public static let jawClenchAddress = "/muse/elements/jaw_clench"
    public static let accelAddress = "/muse/acc"
    public static let gyroAddress = "/muse/gyro"
    public static let eegAddress = "/muse/eeg"

    /// Mind Monitor's horseshoe code for a health status.
    public static func horseshoe(_ status: ChannelHealthStatus) -> Float {
        switch status {
        case .healthy: return 1
        case .unknown: return 2
        case .saturated, .dead, .stale: return 4
        }
    }

    /// All messages for one frame, in a fixed order: five bands, then
    /// horseshoe, then events, then IMU.
    public func messages(for frame: BiofeedbackFrame) -> [OSCMessage] {
        var messages: [OSCMessage] = []

        for band in EEGBand.allCases {
            let arguments: [OSCArgument]
            if perChannel {
                arguments = MindMonitorMirror.channelOrder.map { channel in
                    .float(frame.bandPowers[channel]?.bels(band) ?? BandPowers.bels(0))
                }
            } else {
                var channels = averageOverHealthyChannelsOnly ? frame.healthyChannels : frame.presentChannels
                if channels.isEmpty { channels = frame.presentChannels }
                let values = channels.compactMap { frame.bandPowers[$0]?.bels(band) }
                let mean = values.isEmpty ? BandPowers.bels(0) : values.reduce(0, +) / Float(values.count)
                arguments = [.float(mean)]
            }
            messages.append(OSCMessage(address: band.mindMonitorAbsoluteAddress, arguments: arguments))
        }

        messages.append(OSCMessage(
            address: MindMonitorMirror.horseshoeAddress,
            arguments: MindMonitorMirror.channelOrder.map { .float(MindMonitorMirror.horseshoe(frame.status(of: $0))) }
        ))

        messages += MindMonitorMirror.eventMessages(blink: frame.blink, jawClench: frame.jawClench)
        if let accel = frame.accel {
            messages.append(OSCMessage(address: MindMonitorMirror.accelAddress, arguments: [.float(accel.x), .float(accel.y), .float(accel.z)]))
        }
        if let gyro = frame.gyro {
            messages.append(OSCMessage(address: MindMonitorMirror.gyroAddress, arguments: [.float(gyro.x), .float(gyro.y), .float(gyro.z)]))
        }
        return messages
    }

    /// The two Track A event messages, sent only when true, in Mind Monitor's
    /// shape (one int32 of 1). Split out from `messages(for:)` so
    /// `BiofeedbackCoordinator` can emit events on the classifier's tick
    /// without re-sending the band and horseshoe messages of the window
    /// that preceded it.
    public static func eventMessages(blink: Bool, jawClench: Bool) -> [OSCMessage] {
        var messages: [OSCMessage] = []
        if blink {
            messages.append(OSCMessage(address: blinkAddress, arguments: [.int32(1)]))
        }
        if jawClench {
            messages.append(OSCMessage(address: jawClenchAddress, arguments: [.int32(1)]))
        }
        return messages
    }

    /// Raw EEG re-broadcast in Mind Monitor's `/muse/eeg` format: one
    /// float per channel in microvolts. Only the explicit raw toggle in
    /// the egress configuration should call this; see ADR-011.
    public static func rawEEG(_ sample: EEGSample) -> OSCMessage {
        OSCMessage(address: eegAddress, arguments: sample.channels.map { .float($0) })
    }
}
