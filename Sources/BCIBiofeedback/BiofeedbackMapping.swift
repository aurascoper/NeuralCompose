import Foundation
import BCICore

/// One user-defined route from a feature to an output, with the shaping
/// and the health policy that make it safe to drive a synthesizer with.
///
/// Every mapping has a `HealthPolicy`; there is no way to construct one
/// without deciding what happens when the electrode under the feature is
/// dead, saturated or stale. That is the design difference from passing
/// Mind Monitor straight into a DAW: there the horseshoe shows bad
/// contact while the band powers keep streaming whatever the amplifier
/// saw, and the music follows the artifact.
///
/// The struct is `Codable` so a user's mapping set persists as JSON and
/// so a replay fixture can pin a mapping set alongside its expected
/// output.
public struct BiofeedbackMapping: Sendable, Hashable, Codable, Identifiable {

    /// Where the shaped value goes.
    public enum Target: Sendable, Hashable, Codable {
        /// One float argument, the shaped value in 0 to 1, at `address`.
        /// For Mind Monitor-compatible raw-unit addresses use
        /// `MindMonitorMirror`, not a mapping.
        case osc(address: String)

        /// Control change on `channel` (0 to 15). `fourteenBit` sends the
        /// MSB/LSB pair on `controller` and `controller + 32` and requires
        /// `controller < 32`.
        case midiControl(controller: UInt8, channel: UInt8, fourteenBit: Bool)

        /// Note gate: note on when the shaped value crosses 0.5 upward,
        /// note off when it drops below 0.5 or `gate` seconds elapse,
        /// whichever first. Meant for `.blink` and `.jawClench`.
        case midiNote(note: UInt8, channel: UInt8, velocity: UInt8, gate: TimeInterval)
    }

    /// How the raw feature value is normalised into 0 to 1 before any
    /// smoothing. `inputLow` and `inputHigh` are in the feature's own
    /// units for `.linear`, and are log10'd for `.log10` (so pass
    /// positive linear values, not Bels, when using `.log10`).
    public enum Curve: String, Sendable, Hashable, Codable {
        case linear
        case log10
    }

    /// What to do on ticks where the feature's channels are not healthy.
    public enum HealthPolicy: Sendable, Hashable, Codable {
        /// Emit whatever the feature evaluates to, if anything. Equivalent
        /// to Mind Monitor behaviour; exists so the difference is a user
        /// choice, not a hidden default.
        case passthrough
        /// Keep emitting the last value seen while healthy. Nothing is
        /// emitted until a healthy value has been seen once.
        case holdLast
        /// Glide from the last healthy value toward `rest` with time
        /// constant `tau` seconds.
        case decayToRest(rest: Float, tau: TimeInterval)
        /// Emit nothing. Open note gates are closed on the first unhealthy
        /// tick.
        case mute
    }

    public let id: UUID
    public let feature: BiofeedbackFeature
    public let target: Target
    public let inputLow: Float
    public let inputHigh: Float
    public let curve: Curve

    /// Exponential smoothing time constant in seconds; 0 disables.
    public let smoothingTau: TimeInterval

    /// Minimum seconds between emissions; 0 emits on every tick. MIDI
    /// controls additionally emit only when the quantised value changes.
    public let minInterval: TimeInterval

    public let healthPolicy: HealthPolicy

    public init(
        id: UUID = UUID(),
        feature: BiofeedbackFeature,
        target: Target,
        inputLow: Float,
        inputHigh: Float,
        curve: Curve = .linear,
        smoothingTau: TimeInterval = 0,
        minInterval: TimeInterval = 0,
        healthPolicy: HealthPolicy = .holdLast
    ) {
        precondition(inputHigh != inputLow, "inputLow and inputHigh must differ")
        if curve == .log10 {
            precondition(inputLow > 0 && inputHigh > 0, "log10 curve needs positive input bounds")
        }
        if case .midiControl(let controller, _, let fourteenBit) = target, fourteenBit {
            precondition(controller < 32, "14-bit control change needs controller < 32")
        }
        self.id = id
        self.feature = feature
        self.target = target
        self.inputLow = inputLow
        self.inputHigh = inputHigh
        self.curve = curve
        self.smoothingTau = max(0, smoothingTau)
        self.minInterval = max(0, minInterval)
        self.healthPolicy = healthPolicy
    }

    /// Normalise a raw feature value into 0 to 1 along the curve, clamped.
    public func normalise(_ raw: Float) -> Float {
        let low: Float
        let high: Float
        let x: Float
        switch curve {
        case .linear:
            low = inputLow
            high = inputHigh
            x = raw
        case .log10:
            low = log10(inputLow)
            high = log10(inputHigh)
            x = log10(max(raw, BandPowers.powerFloor))
        }
        let t = (x - low) / (high - low)
        return min(1, max(0, t))
    }
}
