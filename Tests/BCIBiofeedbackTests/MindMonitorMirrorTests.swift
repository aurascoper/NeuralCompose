import XCTest
import BCICore
import BCIEEG
@testable import BCIBiofeedback

/// Pins the Mind Monitor-compatible address scheme and payload shapes
/// against the FAQ table, and checks the whole set survives the trip
/// through `OSCEncoder` and `MuseOSCDecoder`, which is the path a real
/// consumer sees.
final class MindMonitorMirrorTests: XCTestCase {

    private func message(_ messages: [OSCMessage], _ address: String) -> OSCMessage? {
        messages.first { $0.address == address }
    }

    func testAveragedModeSendsFiveBandsWithOneFloatEach() {
        let frame = TestFrames.frame(at: 0, tp9: TestFrames.powers(alpha: 100), af7: TestFrames.powers(alpha: 100), af8: TestFrames.powers(alpha: 1), tp10: TestFrames.powers(alpha: 1))
        let messages = MindMonitorMirror(perChannel: false).messages(for: frame)
        for band in EEGBand.allCases {
            let m = message(messages, "/muse/elements/\(band.rawValue)_absolute")
            XCTAssertNotNil(m, band.rawValue)
            XCTAssertEqual(m?.floatArguments.count, 1)
        }
        // Mean of 2, 2, 0, 0 Bels.
        XCTAssertEqual(message(messages, "/muse/elements/alpha_absolute")?.floatArguments.first ?? -9, 1, accuracy: 1e-6)
    }

    func testPerChannelModeSendsFourFloatsInMuseOrder() {
        let frame = TestFrames.frame(at: 0, tp9: TestFrames.powers(alpha: 1), af7: TestFrames.powers(alpha: 10), af8: TestFrames.powers(alpha: 100), tp10: TestFrames.powers(alpha: 1000))
        let messages = MindMonitorMirror(perChannel: true).messages(for: frame)
        let alpha = message(messages, "/muse/elements/alpha_absolute")?.floatArguments ?? []
        XCTAssertEqual(alpha.count, 4)
        XCTAssertEqual(alpha[0], 0, accuracy: 1e-6)   // TP9
        XCTAssertEqual(alpha[1], 1, accuracy: 1e-6)   // AF7
        XCTAssertEqual(alpha[2], 2, accuracy: 1e-6)   // AF8
        XCTAssertEqual(alpha[3], 3, accuracy: 1e-6)   // TP10
    }

    func testAverageSkipsUnhealthyChannelsButPerChannelDoesNot() {
        let frame = TestFrames.frame(at: 0, tp9: TestFrames.powers(alpha: 100), af7: TestFrames.powers(alpha: 1), af8: TestFrames.powers(alpha: 100), tp10: TestFrames.powers(alpha: 100), health: TestFrames.health(af7: .dead))
        let averaged = MindMonitorMirror(perChannel: false, averageOverHealthyChannelsOnly: true).messages(for: frame)
        XCTAssertEqual(message(averaged, "/muse/elements/alpha_absolute")?.floatArguments.first ?? -9, 2, accuracy: 1e-6)
        let ungated = MindMonitorMirror(perChannel: false, averageOverHealthyChannelsOnly: false).messages(for: frame)
        XCTAssertEqual(message(ungated, "/muse/elements/alpha_absolute")?.floatArguments.first ?? -9, 1.5, accuracy: 1e-6)
        let perChannel = MindMonitorMirror(perChannel: true).messages(for: frame)
        XCTAssertEqual(message(perChannel, "/muse/elements/alpha_absolute")?.floatArguments[1] ?? -9, 0, accuracy: 1e-6, "dead AF7 still occupies its slot")
    }

    func testHorseshoeCodes() {
        XCTAssertEqual(MindMonitorMirror.horseshoe(.healthy), 1)
        XCTAssertEqual(MindMonitorMirror.horseshoe(.unknown), 2)
        XCTAssertEqual(MindMonitorMirror.horseshoe(.saturated), 4)
        XCTAssertEqual(MindMonitorMirror.horseshoe(.dead), 4)
        XCTAssertEqual(MindMonitorMirror.horseshoe(.stale), 4)

        let frame = TestFrames.frame(at: 0, health: [.tp9: .healthy, .af7: .dead, .af8: .unknown, .tp10: .saturated])
        let horseshoe = message(MindMonitorMirror().messages(for: frame), "/muse/elements/horseshoe")
        XCTAssertEqual(horseshoe?.floatArguments, [1, 4, 2, 4])
    }

    func testEventsAreSentOnlyWhenTrue() {
        let quiet = MindMonitorMirror().messages(for: TestFrames.frame(at: 0))
        XCTAssertNil(message(quiet, "/muse/elements/blink"))
        XCTAssertNil(message(quiet, "/muse/elements/jaw_clench"))
        let busy = MindMonitorMirror().messages(for: TestFrames.frame(at: 0, blink: true, jawClench: true))
        XCTAssertEqual(message(busy, "/muse/elements/blink")?.arguments, [OSCArgument.int32(1)])
        XCTAssertEqual(message(busy, "/muse/elements/jaw_clench")?.arguments, [OSCArgument.int32(1)])
    }

    func testIMUIsForwardedWhenPresent() {
        let accel = MovementSample(timestamp: 0, kind: .accel, x: 0.1, y: 0.2, z: 0.3)
        let gyro = MovementSample(timestamp: 0, kind: .gyro, x: -1, y: -2, z: -3)
        let messages = MindMonitorMirror().messages(for: TestFrames.frame(at: 0, accel: accel, gyro: gyro))
        XCTAssertEqual(message(messages, "/muse/acc")?.floatArguments, [0.1, 0.2, 0.3])
        XCTAssertEqual(message(messages, "/muse/gyro")?.floatArguments, [-1, -2, -3])
        XCTAssertNil(message(MindMonitorMirror().messages(for: TestFrames.frame(at: 0)), "/muse/acc"))
    }

    func testMessageOrderIsStable() {
        let messages = MindMonitorMirror().messages(for: TestFrames.frame(at: 0, blink: true))
        XCTAssertEqual(messages.map(\.address), [
            "/muse/elements/delta_absolute",
            "/muse/elements/theta_absolute",
            "/muse/elements/alpha_absolute",
            "/muse/elements/beta_absolute",
            "/muse/elements/gamma_absolute",
            "/muse/elements/horseshoe",
            "/muse/elements/blink",
        ])
    }

    func testRawEEGHelperUsesMindMonitorAddressAndChannelOrder() {
        let sample = EEGSample(timestamp: 0, channels: [801, 802, 803, 804])
        let message = MindMonitorMirror.rawEEG(sample)
        XCTAssertEqual(message.address, "/muse/eeg")
        XCTAssertEqual(message.floatArguments, [801, 802, 803, 804])
    }

    func testWholeTickSurvivesBundleRoundTrip() throws {
        let accel = MovementSample(timestamp: 0, kind: .accel, x: 0, y: 0, z: 1)
        let frame = TestFrames.frame(at: 0, blink: true, accel: accel, gyro: nil)
        let messages = MindMonitorMirror(perChannel: true).messages(for: frame)
        let decoded = try MuseOSCDecoder.decodePacket(OSCEncoder.encodeBundle(messages))
        XCTAssertEqual(decoded, messages)
        // And the existing inbound decoder still recognises the IMU message.
        XCTAssertNotNil(MindMonitorDecoder.movement(from: decoded.last!, timestamp: 0))
    }
}
