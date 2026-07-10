import XCTest
@testable import BCIEEG

/// Pure decoder tests — no networking, no Mind Monitor semantics. This is
/// exactly what keeping `MuseOSCDecoder` (generic OSC) separate from
/// `MindMonitorDecoder` (Mind Monitor semantics) and `MindMonitorOSCStream`
/// (networking) buys: these tests construct raw bytes and assert on
/// decoded values, nothing more.
final class MuseOSCDecoderTests: XCTestCase {

    // MARK: - Test fixture encoder
    //
    // NeuralCompose only ever *receives* OSC (Mind Monitor sends, we
    // listen), so there's no production OSC encoder — this exists purely
    // to construct known-good/known-bad packets for these tests.

    private func oscString(_ s: String) -> Data {
        var data = Data(s.utf8)
        data.append(0)
        while data.count % 4 != 0 { data.append(0) }
        return data
    }

    private func makePacket(address: String, floats: [Float]) -> Data {
        var data = oscString(address)
        data.append(oscString("," + String(repeating: "f", count: floats.count)))
        for f in floats {
            var bits = f.bitPattern.bigEndian
            withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
        }
        return data
    }

    /// Wraps `elements` (each a full, already-framed message or nested
    /// bundle) in `#bundle\0` + an arbitrary 8-byte timetag + one
    /// `[4-byte size][bytes]` entry per element — matching what Mind
    /// Monitor actually sends on the wire (verified via a live capture).
    private func makeBundle(elements: [Data]) -> Data {
        var data = oscString("#bundle")
        data.append(contentsOf: [UInt8](repeating: 0xAB, count: 8)) // arbitrary timetag
        for element in elements {
            var sizeBits = UInt32(element.count).bigEndian
            withUnsafeBytes(of: &sizeBits) { data.append(contentsOf: $0) }
            data.append(element)
        }
        return data
    }

    // MARK: - Valid packets

    func testDecodesMuseEEGPacket() throws {
        let packet = makePacket(address: "/muse/eeg", floats: [12.5, -34.0, 0.0, 999.75])
        let message = try MuseOSCDecoder.decode(packet)
        XCTAssertEqual(message.address, "/muse/eeg")
        XCTAssertEqual(message.floatArguments, [12.5, -34.0, 0.0, 999.75])
    }

    func testDecodesZeroArgumentMessage() throws {
        var data = oscString("/muse/batt")
        data.append(oscString(","))
        let message = try MuseOSCDecoder.decode(data)
        XCTAssertEqual(message.address, "/muse/batt")
        XCTAssertEqual(message.arguments, [])
    }

    func testDecodesIntAndStringArguments() throws {
        var data = oscString("/test/mixed")
        data.append(oscString(",is"))
        var intBits = Int32(42).bigEndian
        withUnsafeBytes(of: &intBits) { data.append(contentsOf: $0) }
        data.append(oscString("hello"))
        let message = try MuseOSCDecoder.decode(data)
        XCTAssertEqual(message.arguments, [.int32(42), .string("hello")])
    }

    func testAddressPaddingToFourByteBoundary() throws {
        // "/a" (2 chars) + null = 3 bytes, padded to 4. Verify the reader
        // advances past the padding correctly by decoding a follow-on
        // argument successfully.
        let packet = makePacket(address: "/a", floats: [1.0])
        let message = try MuseOSCDecoder.decode(packet)
        XCTAssertEqual(message.address, "/a")
        XCTAssertEqual(message.floatArguments, [1.0])
    }

    // MARK: - Malformed packets

    func testThrowsOnEmptyData() {
        XCTAssertThrowsError(try MuseOSCDecoder.decode(Data()))
    }

    func testThrowsOnMissingTypeTag() {
        // Address with no comma-prefixed type tag string following it.
        var data = oscString("/muse/eeg")
        data.append(contentsOf: [0, 0, 0, 0]) // not a "," start
        XCTAssertThrowsError(try MuseOSCDecoder.decode(data)) { error in
            XCTAssertEqual(error as? OSCDecodingError, .missingTypeTagString)
        }
    }

    func testThrowsOnTruncatedFloatArgument() {
        var data = oscString("/muse/eeg")
        data.append(oscString(",f"))
        data.append(contentsOf: [0, 0]) // only 2 of 4 required bytes
        XCTAssertThrowsError(try MuseOSCDecoder.decode(data)) { error in
            guard case .truncatedArgument = error as? OSCDecodingError else {
                return XCTFail("expected .truncatedArgument, got \(error)")
            }
        }
    }

    func testThrowsOnUnsupportedTypeTag() {
        var data = oscString("/muse/eeg")
        data.append(oscString(",b")) // blob — not supported
        XCTAssertThrowsError(try MuseOSCDecoder.decode(data)) { error in
            guard case .unsupportedTypeTag = error as? OSCDecodingError else {
                return XCTFail("expected .unsupportedTypeTag, got \(error)")
            }
        }
    }

    func testThrowsOnUnterminatedAddressString() {
        // No null terminator anywhere in the buffer.
        let data = Data([UInt8(ascii: "/"), UInt8(ascii: "a")])
        XCTAssertThrowsError(try MuseOSCDecoder.decode(data))
    }

    // MARK: - decodePacket / bundle unwrapping
    //
    // Mind Monitor wraps every message in an OSC bundle, even a single
    // one — decode(_:) alone rejects 100% of its real traffic (found via
    // live testing over Tailscale: every /muse/* packet on the wire opens
    // with "#bundle\0", not a bare address string). decodePacket(_:) is
    // the fix; these tests pin the format down.

    func testDecodePacketUnwrapsRealMindMonitorGyroBundle() throws {
        // Exact bytes captured from a live Mind Monitor session (Android,
        // default OSC settings) — one #bundle wrapping a single
        // /muse/gyro,fff message. Regression test for the real integration
        // gap, not just the format as documented.
        let hex = "2362756e646c6500edfbaee5024dd2f1000000202f6d7573652f6779726f00002c666666"
            + "000000003e822800c0296500bfaa5a00"
        let bytes = stride(from: 0, to: hex.count, by: 2).map { i -> UInt8 in
            let start = hex.index(hex.startIndex, offsetBy: i)
            let end = hex.index(start, offsetBy: 2)
            return UInt8(hex[start..<end], radix: 16)!
        }
        let packet = Data(bytes)

        let messages = try MuseOSCDecoder.decodePacket(packet)
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0].address, "/muse/gyro")
        XCTAssertEqual(messages[0].floatArguments.count, 3)
    }

    func testDecodePacketReturnsBareMessageUnwrapped() throws {
        let packet = makePacket(address: "/muse/eeg", floats: [1, 2, 3, 4])
        let messages = try MuseOSCDecoder.decodePacket(packet)
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0].address, "/muse/eeg")
        XCTAssertEqual(messages[0].floatArguments, [1, 2, 3, 4])
    }

    func testDecodePacketHandlesMultipleElementsInOneBundle() throws {
        let eeg = makePacket(address: "/muse/eeg", floats: [1, 2, 3, 4])
        let gyro = makePacket(address: "/muse/gyro", floats: [0.1, 0.2, 0.3])
        let bundle = makeBundle(elements: [eeg, gyro])

        let messages = try MuseOSCDecoder.decodePacket(bundle)
        XCTAssertEqual(messages.map(\.address), ["/muse/eeg", "/muse/gyro"])
    }

    func testDecodePacketHandlesNestedBundle() throws {
        let eeg = makePacket(address: "/muse/eeg", floats: [1, 2, 3, 4])
        let innerBundle = makeBundle(elements: [eeg])
        let outerBundle = makeBundle(elements: [innerBundle])

        let messages = try MuseOSCDecoder.decodePacket(outerBundle)
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0].address, "/muse/eeg")
    }

    /// Exercises the recursive branch and the non-recursive branch of
    /// decodeBundleElements' `if isBundle(element) { ... } else { ... }`
    /// within the *same* loop, not just in isolation — a plain message
    /// and a nested sub-bundle as siblings inside one outer bundle. This
    /// is the shape a future refactor (e.g. flattening the recursion into
    /// a single pass) is most likely to regress without noticing, since
    /// the purely-flat and purely-nested cases alone wouldn't catch it.
    func testDecodePacketUnwrapsNestedBundleAlongsideSiblingMessage() throws {
        let batt = makePacket(address: "/muse/batt", floats: [98])
        let eeg = makePacket(address: "/muse/eeg", floats: [1, 2, 3, 4])
        let subBundle = makeBundle(elements: [eeg])
        let outerBundle = makeBundle(elements: [batt, subBundle])

        let messages = try MuseOSCDecoder.decodePacket(outerBundle)
        XCTAssertEqual(messages.map(\.address), ["/muse/batt", "/muse/eeg"])
    }

    func testDecodePacketThrowsOnTruncatedBundleElement() {
        var bundle = oscString("#bundle")
        bundle.append(contentsOf: [UInt8](repeating: 0, count: 8)) // timetag
        var sizeBits = UInt32(999).bigEndian // claims 999 bytes follow
        withUnsafeBytes(of: &sizeBits) { bundle.append(contentsOf: $0) }
        bundle.append(contentsOf: [0, 0]) // only 2 actually follow

        XCTAssertThrowsError(try MuseOSCDecoder.decodePacket(bundle)) { error in
            guard case .truncatedArgument = error as? OSCDecodingError else {
                return XCTFail("expected .truncatedArgument, got \(error)")
            }
        }
    }
}
