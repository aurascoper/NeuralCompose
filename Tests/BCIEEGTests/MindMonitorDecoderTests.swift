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

    func testIgnoresEEGAddressWithWrongArgumentCount() {
        let tooFew = OSCMessage(address: "/muse/eeg", arguments: [.float(1), .float(2), .float(3)])
        XCTAssertNil(MindMonitorDecoder.sample(from: tooFew, timestamp: 0))

        let tooMany = OSCMessage(address: "/muse/eeg", arguments: [
            .float(1), .float(2), .float(3), .float(4), .float(5),
        ])
        XCTAssertNil(MindMonitorDecoder.sample(from: tooMany, timestamp: 0))
    }

    func testIgnoresEEGAddressWithNonFloatArguments() {
        let message = OSCMessage(address: "/muse/eeg", arguments: [
            .string("not"), .string("floats"), .int32(1), .int32(2),
        ])
        XCTAssertNil(MindMonitorDecoder.sample(from: message, timestamp: 0))
    }
}
