import Foundation

/// A MIDI 1.0 channel-voice event, independent of any transport.
///
/// Channels are zero-based here (0 to 15) and shown to users one-based
/// (1 to 16), the usual DAW convention. Values are already clamped to 7
/// bits by the constructors that produce them (`FeatureMapper`); the
/// encoders below mask defensively anyway.
///
/// Two encodings are provided because CoreMIDI on macOS 11+ prefers the
/// Universal MIDI Packet (`umpWord`, used by `CoreMIDIVirtualSource`),
/// while anything that writes classic MIDI bytes (a file, a serial port,
/// a test fixture) wants `bytes`. Both are pure functions and both are
/// covered by `MIDIEventTests`.
public enum MIDIEvent: Sendable, Hashable, Codable {
    case controlChange(channel: UInt8, controller: UInt8, value: UInt8)
    case noteOn(channel: UInt8, note: UInt8, velocity: UInt8)
    case noteOff(channel: UInt8, note: UInt8)

    /// Classic MIDI 1.0 wire bytes: status, data1, data2.
    public var bytes: [UInt8] {
        switch self {
        case .controlChange(let channel, let controller, let value):
            return [0xB0 | (channel & 0x0F), controller & 0x7F, value & 0x7F]
        case .noteOn(let channel, let note, let velocity):
            return [0x90 | (channel & 0x0F), note & 0x7F, velocity & 0x7F]
        case .noteOff(let channel, let note):
            return [0x80 | (channel & 0x0F), note & 0x7F, 0]
        }
    }

    /// The event as one 32-bit Universal MIDI Packet word: message type 2
    /// (MIDI 1.0 channel voice), group 0, then the three classic bytes.
    public var umpWord: UInt32 {
        let b = bytes
        return (0x2 << 28) | (UInt32(b[0]) << 16) | (UInt32(b[1]) << 8) | UInt32(b[2])
    }

    /// A 14-bit control change as the MSB/LSB pair MIDI 1.0 defines:
    /// controller `n` (0 to 31) carries the high 7 bits and controller
    /// `n + 32` the low 7 bits, MSB first. Controllers 32 and above have
    /// no LSB partner and fall back to a single 7-bit message carrying the
    /// high bits.
    public static func controlChange14(channel: UInt8, controller: UInt8, value: UInt16) -> [MIDIEvent] {
        let v = min(value, 16383)
        let msb = UInt8((v >> 7) & 0x7F)
        let lsb = UInt8(v & 0x7F)
        guard controller < 32 else {
            return [.controlChange(channel: channel, controller: controller, value: msb)]
        }
        return [
            .controlChange(channel: channel, controller: controller, value: msb),
            .controlChange(channel: channel, controller: controller + 32, value: lsb),
        ]
    }
}
