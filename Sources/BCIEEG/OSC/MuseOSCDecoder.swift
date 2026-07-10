import Foundation

/// A decoded OSC 1.0 message: an address pattern plus its typed arguments.
/// Pure data — no networking, no semantic interpretation of what the
/// address means. That's `MindMonitorDecoder`'s job; keeping the two
/// separate is what makes `MuseOSCDecoder` trivially testable with raw
/// bytes and reusable if this project ever speaks OSC to something that
/// isn't Mind Monitor.
public struct OSCMessage: Equatable, Sendable {
    public let address: String
    public let arguments: [OSCArgument]

    public init(address: String, arguments: [OSCArgument]) {
        self.address = address
        self.arguments = arguments
    }

    /// This message's arguments as `Float`, dropping (not coercing) any
    /// non-float argument. Empty if none are floats.
    public var floatArguments: [Float] {
        arguments.compactMap {
            if case .float(let f) = $0 { return f }
            return nil
        }
    }
}

public enum OSCArgument: Equatable, Sendable {
    case int32(Int32)
    case float(Float)
    case string(String)
}

public enum OSCDecodingError: Error, Sendable, Equatable {
    case tooShort
    case missingTypeTagString
    case unsupportedTypeTag(String)
    case truncatedArgument(expected: Int, remaining: Int)
    case malformedString
}

/// Minimal OSC 1.0 message decoder — supports int32 (`i`), float32 (`f`),
/// and string (`s`) arguments, which covers everything Mind Monitor's
/// `/muse/*` addresses actually use.
///
/// Does **not** decode OSC bundles (packets whose first 8 bytes are
/// `#bundle\0`, wrapping multiple timestamped messages). Mind Monitor's
/// default configuration sends bare messages, not bundles. Add bundle
/// support here — not in `MindMonitorOSCStream` — if a Mind Monitor config
/// that bundles is ever needed; it's a decoding concern, not a networking
/// one.
public enum MuseOSCDecoder {

    public static func decode(_ data: Data) throws -> OSCMessage {
        var offset = data.startIndex
        let address = try readOSCString(data, &offset)

        guard offset < data.endIndex, data[offset] == UInt8(ascii: ",") else {
            throw OSCDecodingError.missingTypeTagString
        }
        let typeTag = try readOSCString(data, &offset)
        let typeChars = typeTag.dropFirst() // drop the leading ","

        var arguments: [OSCArgument] = []
        arguments.reserveCapacity(typeChars.count)
        for typeChar in typeChars {
            switch typeChar {
            case "i":
                arguments.append(.int32(try readInt32(data, &offset)))
            case "f":
                arguments.append(.float(try readFloat32(data, &offset)))
            case "s":
                arguments.append(.string(try readOSCString(data, &offset)))
            default:
                throw OSCDecodingError.unsupportedTypeTag(String(typeChar))
            }
        }
        return OSCMessage(address: address, arguments: arguments)
    }

    // MARK: - Primitive readers

    /// OSC strings are ASCII, null-terminated, then padded with additional
    /// null bytes so the *total* consumed length (including the
    /// terminator) is a multiple of 4.
    private static func readOSCString(_ data: Data, _ offset: inout Data.Index) throws -> String {
        guard offset < data.endIndex else { throw OSCDecodingError.tooShort }
        var end = offset
        while end < data.endIndex, data[end] != 0 { end = data.index(after: end) }
        guard end < data.endIndex else { throw OSCDecodingError.malformedString }
        guard let str = String(data: data[offset..<end], encoding: .utf8) else {
            throw OSCDecodingError.malformedString
        }
        let consumedBeforePadding = data.distance(from: offset, to: end) + 1 // + null terminator
        let padded = ((consumedBeforePadding + 3) / 4) * 4
        let newOffset = data.index(offset, offsetBy: padded)
        guard newOffset <= data.endIndex else { throw OSCDecodingError.tooShort }
        offset = newOffset
        return str
    }

    private static func readInt32(_ data: Data, _ offset: inout Data.Index) throws -> Int32 {
        Int32(bitPattern: try readBigEndianU32(data, &offset))
    }

    private static func readFloat32(_ data: Data, _ offset: inout Data.Index) throws -> Float {
        Float(bitPattern: try readBigEndianU32(data, &offset))
    }

    private static func readBigEndianU32(_ data: Data, _ offset: inout Data.Index) throws -> UInt32 {
        let size = 4
        guard data.distance(from: offset, to: data.endIndex) >= size else {
            throw OSCDecodingError.truncatedArgument(
                expected: size, remaining: data.distance(from: offset, to: data.endIndex)
            )
        }
        var value: UInt32 = 0
        for i in 0..<size {
            value = (value << 8) | UInt32(data[data.index(offset, offsetBy: i)])
        }
        offset = data.index(offset, offsetBy: size)
        return value
    }
}
