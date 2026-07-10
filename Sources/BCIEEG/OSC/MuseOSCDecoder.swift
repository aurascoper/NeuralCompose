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
public enum MuseOSCDecoder {

    /// Decodes a raw UDP payload into zero or more messages. This is the
    /// entry point transports should call — not `decode(_:)` directly —
    /// because Mind Monitor wraps *every* message it sends in an OSC
    /// bundle (`#bundle\0` + an 8-byte NTP timetag + one or more
    /// length-prefixed elements, each itself a message or a nested
    /// bundle), even when there's only one message in it. Verified against
    /// a live capture: every `/muse/*` packet Mind Monitor actually sends
    /// on the wire starts with `#bundle\0`, not a bare address string.
    ///
    /// Bare (non-bundle) messages are still accepted directly, so this
    /// also works against any OSC sender that doesn't bundle.
    public static func decodePacket(_ data: Data) throws -> [OSCMessage] {
        if isBundle(data) {
            return try decodeBundleElements(data)
        }
        return [try decode(data)]
    }

    private static let bundlePrefix: [UInt8] = Array("#bundle\0".utf8)

    private static func isBundle(_ data: Data) -> Bool {
        data.count >= bundlePrefix.count && data.prefix(bundlePrefix.count).elementsEqual(bundlePrefix)
    }

    /// `data` is `#bundle\0` (8 bytes) + an 8-byte NTP timetag (ignored —
    /// this project only cares about local arrival timing, not the
    /// sender's clock) + a sequence of `[4-byte size][element bytes]`
    /// entries, each element being a message or a nested bundle.
    private static func decodeBundleElements(_ data: Data) throws -> [OSCMessage] {
        guard data.count >= 16 else { throw OSCDecodingError.tooShort }
        var offset = data.index(data.startIndex, offsetBy: 16)

        var messages: [OSCMessage] = []
        while offset < data.endIndex {
            let size = try Int(readBigEndianU32(data, &offset))
            guard data.distance(from: offset, to: data.endIndex) >= size else {
                throw OSCDecodingError.truncatedArgument(
                    expected: size, remaining: data.distance(from: offset, to: data.endIndex)
                )
            }
            let elementEnd = data.index(offset, offsetBy: size)
            let element = data[offset..<elementEnd]
            if isBundle(element) {
                messages.append(contentsOf: try decodeBundleElements(element))
            } else {
                messages.append(try decode(element))
            }
            offset = elementEnd
        }
        return messages
    }

    /// Decodes a single bare OSC message — no bundle framing. Prefer
    /// `decodePacket(_:)` for anything read off a socket.
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
