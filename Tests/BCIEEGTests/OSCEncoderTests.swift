import XCTest
@testable import BCIEEG

/// The encoder is the mirror of `MuseOSCDecoder`, so the property that
/// matters is the round trip through the decoder that already guards the
/// inbound path. A few byte-exact checks pin the wire format against the
/// OSC 1.0 spec independently of the decoder.
final class OSCEncoderTests: XCTestCase {

    // MARK: - Byte-exact

    func testPaddedStringAppendsNULAndPadsToFourBytes() {
        XCTAssertEqual(Array(OSCEncoder.paddedString("/a")), [0x2F, 0x61, 0x00, 0x00])
        // Exactly three characters needs one NUL to reach four bytes.
        XCTAssertEqual(Array(OSCEncoder.paddedString("abc")), [0x61, 0x62, 0x63, 0x00])
        // Exactly four characters needs a NUL and then three more of padding.
        XCTAssertEqual(OSCEncoder.paddedString("abcd").count, 8)
    }

    func testSingleFloatMessageBytes() {
        let data = OSCEncoder.encode(OSCMessage(address: "/a", arguments: [.float(1.0)]))
        // "/a\0\0" + ",f\0\0" + 0x3F800000 big-endian
        XCTAssertEqual(Array(data), [0x2F, 0x61, 0x00, 0x00, 0x2C, 0x66, 0x00, 0x00, 0x3F, 0x80, 0x00, 0x00])
    }

    func testBundleHeaderAndElementSize() {
        let message = OSCMessage(address: "/a", arguments: [.int32(7)])
        let data = OSCEncoder.encodeBundle([message])
        let bytes = Array(data)
        XCTAssertEqual(Array(bytes[0..<8]), Array("#bundle".utf8) + [0x00])
        XCTAssertEqual(Array(bytes[8..<16]), [0, 0, 0, 0, 0, 0, 0, 1], "immediate timetag")
        let element = OSCEncoder.encode(message)
        XCTAssertEqual(Array(bytes[16..<20]), [0, 0, 0, UInt8(element.count)])
        XCTAssertEqual(Array(bytes[20...]), Array(element))
    }

    // MARK: - Round trip

    func testBareMessageRoundTrip() throws {
        let message = OSCMessage(address: "/muse/elements/alpha_absolute", arguments: [
            .float(0.25), .float(-1.5), .float(0), .float(2.0),
        ])
        let decoded = try MuseOSCDecoder.decode(OSCEncoder.encode(message))
        XCTAssertEqual(decoded, message)
    }

    func testMixedArgumentRoundTrip() throws {
        let message = OSCMessage(address: "/nc/test", arguments: [
            .int32(1), .float(3.5), .string("hello"), .int32(-2), .string("four"),
        ])
        let decoded = try MuseOSCDecoder.decode(OSCEncoder.encode(message))
        XCTAssertEqual(decoded, message)
    }

    func testBundleRoundTripPreservesOrder() throws {
        let messages = [
            OSCMessage(address: "/muse/elements/alpha_absolute", arguments: [.float(0.5)]),
            OSCMessage(address: "/muse/elements/horseshoe", arguments: [.float(1), .float(2), .float(4), .float(1)]),
            OSCMessage(address: "/muse/elements/blink", arguments: [.int32(1)]),
        ]
        let decoded = try MuseOSCDecoder.decodePacket(OSCEncoder.encodeBundle(messages))
        XCTAssertEqual(decoded, messages)
    }

    func testBareMessageAlsoDecodesThroughPacketPath() throws {
        let message = OSCMessage(address: "/muse/acc", arguments: [.float(0.1), .float(-0.9), .float(0.0)])
        let decoded = try MuseOSCDecoder.decodePacket(OSCEncoder.encode(message))
        XCTAssertEqual(decoded, [message])
    }
}
