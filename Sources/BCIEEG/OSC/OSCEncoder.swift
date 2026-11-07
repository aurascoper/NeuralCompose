import Foundation

/// Minimal OSC 1.0 message and bundle encoder. The exact mirror of
/// `MuseOSCDecoder`: int32 (`i`), float32 (`f`) and string (`s`)
/// arguments, 4-byte alignment, big-endian numerics. Pure data in, pure
/// bytes out; no networking and no opinion about what an address means.
///
/// Until ADR-011 NeuralCompose only ever *received* OSC, so the only
/// encoder in the tree was a private test helper in
/// `MuseOSCDecoderTests`. This is that helper promoted to production,
/// because the biofeedback egress (`BCIBiofeedback`) needs to send the
/// same wire format Mind Monitor sends, so that downstream consumers
/// written against Mind Monitor (Max for Live devices, TouchDesigner,
/// SuperCollider patches) work unchanged.
///
/// Round-trip property, enforced by `OSCEncoderTests`:
/// `MuseOSCDecoder.decode(OSCEncoder.encode(m)) == m` for every message
/// whose arguments are int32 / float32 / string, and
/// `MuseOSCDecoder.decodePacket(OSCEncoder.encodeBundle(ms)) == ms`.
public enum OSCEncoder {

    /// The OSC "immediately" timetag: a 64-bit NTP value of exactly 1.
    public static let immediateTimetag: UInt64 = 1

    /// Encodes one bare message (no bundle framing).
    public static func encode(_ message: OSCMessage) -> Data {
        var data = paddedString(message.address)
        var typeTags = ","
        for argument in message.arguments {
            switch argument {
            case .int32:  typeTags.append("i")
            case .float:  typeTags.append("f")
            case .string: typeTags.append("s")
            }
        }
        data.append(paddedString(typeTags))
        for argument in message.arguments {
            switch argument {
            case .int32(let value):
                appendBigEndian(UInt32(bitPattern: value), to: &data)
            case .float(let value):
                appendBigEndian(value.bitPattern, to: &data)
            case .string(let value):
                data.append(paddedString(value))
            }
        }
        return data
    }

    /// Encodes one OSC bundle containing `messages`, in order, with the
    /// given NTP timetag (default: immediately). Mind Monitor wraps every
    /// message it sends in a bundle, so consumers built against it expect
    /// this framing; `MuseOSCDecoder.decodePacket` unwraps it.
    public static func encodeBundle(_ messages: [OSCMessage], timetag: UInt64 = immediateTimetag) -> Data {
        var data = paddedString("#bundle")
        appendBigEndian(timetag, to: &data)
        for message in messages {
            let element = encode(message)
            appendBigEndian(UInt32(element.count), to: &data)
            data.append(element)
        }
        return data
    }

    /// An OSC string: UTF-8 bytes, a NUL terminator, then NUL padding up
    /// to the next multiple of four bytes.
    public static func paddedString(_ string: String) -> Data {
        var data = Data(string.utf8)
        data.append(0)
        while data.count % 4 != 0 { data.append(0) }
        return data
    }

    private static func appendBigEndian<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var bigEndian = value.bigEndian
        withUnsafeBytes(of: &bigEndian) { data.append(contentsOf: $0) }
    }
}
