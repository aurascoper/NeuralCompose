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
}
