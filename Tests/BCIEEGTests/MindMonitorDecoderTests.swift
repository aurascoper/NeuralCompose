import XCTest
@testable import BCIEEG
@testable import BCICore

/// `MindMonitorDecoder` maps already-decoded `OSCMessage`s to `EEGSample`s
/// — no bytes, no sockets, just the semantic mapping. That separation
/// (see `MindMonitorDecoder`'s doc comment) is what makes these tests
/// trivial to write and fast to run.
final class MindMonitorDecoderTests: XCTestCase {

    func testMapsMuseEEGMessageToSample() {
        let message = OSCMessage(address: "/muse/eeg", arguments: [
            .float(10.0), .float(-20.0), .float(30.0), .float(-40.0),
        ])
        let sample = MindMonitorDecoder.sample(from: message, timestamp: 1.5)
        XCTAssertEqual(sample?.timestamp, 1.5)
        XCTAssertEqual(sample?.channels, [10.0, -20.0, 30.0, -40.0])
    }

    func testIgnoresNonEEGAddresses() {
        for address in ["/muse/acc", "/muse/gyro", "/muse/batt", "/muse/elements/touching_forehead"] {
            let message = OSCMessage(address: address, arguments: [.float(1), .float(2), .float(3)])
            XCTAssertNil(
                MindMonitorDecoder.sample(from: message, timestamp: 0),
                "\(address) should be ignored, not decoded as an EEG sample"
            )
        }
    }

    func testIgnoresEEGAddressWithFewerThanFourArguments() {
        let tooFew = OSCMessage(address: "/muse/eeg", arguments: [.float(1), .float(2), .float(3)])
        XCTAssertNil(MindMonitorDecoder.sample(from: tooFew, timestamp: 0))
    }

    /// Real Mind Monitor sends 6 floats per `/muse/eeg` message, not 4 —
    /// found via a live capture against a real device (every real EEG
    /// packet was being silently dropped as "wrong argument count" before
    /// this was fixed). Extra trailing floats beyond the first 4 are
    /// accepted and dropped, not rejected.
    func testAcceptsEEGAddressWithMoreThanFourArgumentsUsingFirstFour() {
        let sixFloats = OSCMessage(address: "/muse/eeg", arguments: [
            .float(1), .float(2), .float(3), .float(4), .float(5), .float(6),
        ])
        let sample = MindMonitorDecoder.sample(from: sixFloats, timestamp: 0)
        XCTAssertEqual(sample?.channels, [1, 2, 3, 4], "should use only the first 4 floats, dropping the rest")
    }

    /// Byte-for-byte from a live Mind Monitor capture (see
    /// MindMonitorOSCStream's doc comment and commit history around the
    /// bundle-unwrap fix) — a real `/muse/eeg` OSC message with 6 floats,
    /// decoded through the real `MuseOSCDecoder` first so this test also
    /// pins the two decoders composing correctly on real bytes, not just
    /// on a hand-built `OSCMessage`.
    func testDecodesRealCapturedSixFloatEEGMessage() throws {
        let hex = "2f6d7573652f6565670000002c6666666666660044533c7c00000000444fe97f444d1771442f601e440a4e4d"
        let bytes = stride(from: 0, to: hex.count, by: 2).map { i -> UInt8 in
            let start = hex.index(hex.startIndex, offsetBy: i)
            let end = hex.index(start, offsetBy: 2)
            return UInt8(hex[start..<end], radix: 16)!
        }
        let message = try MuseOSCDecoder.decode(Data(bytes))
        XCTAssertEqual(message.address, "/muse/eeg")
        XCTAssertEqual(message.floatArguments.count, 6)

        let sample = MindMonitorDecoder.sample(from: message, timestamp: 2.0)
        XCTAssertNotNil(sample, "a real captured 6-float /muse/eeg message must decode to a sample")
        XCTAssertEqual(sample?.channels.count, 4)
    }

    func testIgnoresEEGAddressWithNonFloatArguments() {
        let message = OSCMessage(address: "/muse/eeg", arguments: [
            .string("not"), .string("floats"), .int32(1), .int32(2),
        ])
        XCTAssertNil(MindMonitorDecoder.sample(from: message, timestamp: 0))
    }

    // MARK: - Movement (accel / gyro)

    func testMapsAccelMessageToMovementSample() {
        let message = OSCMessage(address: "/muse/acc", arguments: [.float(0.1), .float(-0.2), .float(0.98)])
        let m = MindMonitorDecoder.movement(from: message, timestamp: 3.0)
        XCTAssertEqual(m?.kind, .accel)
        XCTAssertEqual(m?.timestamp, 3.0)
        XCTAssertEqual(m.map { [$0.x, $0.y, $0.z] }, [0.1, -0.2, 0.98])
    }

    func testMapsGyroMessageToMovementSample() {
        let message = OSCMessage(address: "/muse/gyro", arguments: [.float(1), .float(2), .float(3), .float(4)])
        let m = MindMonitorDecoder.movement(from: message, timestamp: 0)
        XCTAssertEqual(m?.kind, .gyro)
        XCTAssertEqual(m.map { [$0.x, $0.y, $0.z] }, [1, 2, 3], "uses the first 3 floats")
    }

    func testMovementIgnoresEEGAndUnknownAddresses() {
        for address in ["/muse/eeg", "/muse/batt", "/muse/elements/blink"] {
            let message = OSCMessage(address: address, arguments: [.float(1), .float(2), .float(3)])
            XCTAssertNil(MindMonitorDecoder.movement(from: message, timestamp: 0),
                         "\(address) is not a movement message")
        }
    }

    func testMovementIgnoresFewerThanThreeFloats() {
        let tooFew = OSCMessage(address: "/muse/acc", arguments: [.float(1), .float(2)])
        XCTAssertNil(MindMonitorDecoder.movement(from: tooFew, timestamp: 0))
    }
}
