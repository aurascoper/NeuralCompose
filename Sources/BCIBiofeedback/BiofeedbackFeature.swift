import Foundation
import BCICore

/// A scalar a user can map to an OSC address or a MIDI control. Each case
/// names exactly what it reads from a `BiofeedbackFrame` and in what
/// units, so a mapping's input range is meaningful without reading code.
///
/// Channel-averaged variants (`channel == nil`) average over the frame's
/// *healthy* channels when asked to, falling back to all present
/// channels when none is healthy. Averaging happens in the feature's own
/// units (Bels for absolute power, fractions for relative power), which
/// matches Mind Monitor's "single combined average value" semantics as far
/// as its documentation states them.
public enum BiofeedbackFeature: Sendable, Hashable, Codable {

    public enum Axis: String, Sendable, Hashable, Codable, CaseIterable {
        case x, y, z
    }

    /// Absolute band power in Bels (log10 µV²). Typical Muse range
    /// roughly -1 to 2.5 Bels after demeaning.
    case bandAbsolute(EEGBand, channel: EEGChannel?)

    /// Fraction of total band power in the band, 0 to 1.
    case bandRelative(EEGBand, channel: EEGChannel?)

    /// Ratio of two linear band powers, e.g. theta/beta. Unbounded above;
    /// use a `.log10` curve or a tight input range.
    case bandRatio(numerator: EEGBand, denominator: EEGBand, channel: EEGChannel?)

    /// 1 when the channel is healthy, 0.5 when unknown, 0 when saturated,
    /// dead or stale.
    case channelQuality(EEGChannel)

    /// 1 on a tick that carries a Track A blink, else 0.
    case blink

    /// 1 on a tick that carries a Track A jaw clench, else 0.
    case jawClench

    /// Accelerometer axis in g (Mind Monitor range -2 to +2).
    case accel(Axis)

    /// Gyroscope axis in degrees per second (Mind Monitor range -245 to +245).
    case gyro(Axis)

    /// The channels whose health gates this feature. Empty for features
    /// that do not read EEG. For channel-averaged features this is every
    /// channel, and the gate is "at least one healthy" rather than "all
    /// healthy"; see `isHealthy(in:)`.
    public var requiredChannels: Set<EEGChannel> {
        switch self {
        case .bandAbsolute(_, let channel), .bandRelative(_, let channel), .bandRatio(_, _, let channel):
            if let channel { return [channel] }
            return Set(EEGChannel.allCases)
        case .channelQuality, .blink, .jawClench, .accel, .gyro:
            return []
        }
    }

    /// Whether the frame is healthy enough for this feature to be trusted.
    /// Single-channel features require that channel healthy; averaged
    /// features require at least one healthy channel present; non-EEG
    /// features are always healthy.
    public func isHealthy(in frame: BiofeedbackFrame) -> Bool {
        switch self {
        case .bandAbsolute(_, let channel), .bandRelative(_, let channel), .bandRatio(_, _, let channel):
            if let channel { return frame.status(of: channel) == .healthy }
            return !frame.healthyChannels.isEmpty
        case .channelQuality, .blink, .jawClench, .accel, .gyro:
            return true
        }
    }

    /// Evaluate the feature on `frame`. Returns `nil` when the frame does
    /// not carry what the feature needs (channel absent, no IMU sample),
    /// never a made-up default. `healthyOnly` restricts channel-averaged
    /// features to healthy channels when any exist.
    public func evaluate(in frame: BiofeedbackFrame, healthyOnly: Bool = true) -> Float? {
        switch self {
        case .bandAbsolute(let band, let channel):
            return average(over: channel, in: frame, healthyOnly: healthyOnly) { $0.bels(band) }

        case .bandRelative(let band, let channel):
            return average(over: channel, in: frame, healthyOnly: healthyOnly) { $0.relative(band) }

        case .bandRatio(let numerator, let denominator, let channel):
            return average(over: channel, in: frame, healthyOnly: healthyOnly) { powers in
                let d = powers[denominator]
                guard d > 0 else { return nil }
                return powers[numerator] / d
            }

        case .channelQuality(let channel):
            switch frame.status(of: channel) {
            case .healthy: return 1
            case .unknown: return 0.5
            case .saturated, .dead, .stale: return 0
            }

        case .blink:
            return frame.blink ? 1 : 0

        case .jawClench:
            return frame.jawClench ? 1 : 0

        case .accel(let axis):
            guard let sample = frame.accel else { return nil }
            return component(axis, of: sample)

        case .gyro(let axis):
            guard let sample = frame.gyro else { return nil }
            return component(axis, of: sample)
        }
    }

    private func average(
        over channel: EEGChannel?,
        in frame: BiofeedbackFrame,
        healthyOnly: Bool,
        _ read: (BandPowers) -> Float?
    ) -> Float? {
        if let channel {
            guard let powers = frame.bandPowers[channel] else { return nil }
            return read(powers)
        }
        var channels = healthyOnly ? frame.healthyChannels : frame.presentChannels
        if channels.isEmpty { channels = frame.presentChannels }
        var sum: Float = 0
        var count = 0
        for channel in channels {
            guard let powers = frame.bandPowers[channel], let value = read(powers) else { continue }
            sum += value
            count += 1
        }
        return count > 0 ? sum / Float(count) : nil
    }

    private func component(_ axis: Axis, of sample: MovementSample) -> Float {
        switch axis {
        case .x: return sample.x
        case .y: return sample.y
        case .z: return sample.z
        }
    }
}
