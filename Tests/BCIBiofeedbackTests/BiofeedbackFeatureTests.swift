import XCTest
import BCICore
@testable import BCIBiofeedback

final class BiofeedbackFeatureTests: XCTestCase {

    func testSingleChannelAbsoluteIsBels() {
        let frame = TestFrames.frame(at: 0, tp9: TestFrames.powers(alpha: 100))
        XCTAssertEqual(BiofeedbackFeature.bandAbsolute(.alpha, channel: .tp9).evaluate(in: frame) ?? -99, 2, accuracy: 1e-6)
    }

    func testAbsentChannelEvaluatesToNil() {
        let frame = TestFrames.frame(at: 0, af7: nil)
        XCTAssertNil(BiofeedbackFeature.bandAbsolute(.alpha, channel: .af7).evaluate(in: frame))
        XCTAssertNil(BiofeedbackFeature.bandRelative(.alpha, channel: .af7).evaluate(in: frame))
    }

    func testAveragedAbsoluteUsesHealthyChannelsOnly() {
        // TP9 and TP10 at 100 µV² (2 Bels), AF7 at 1 µV² (0 Bels) but dead,
        // AF8 at 100 µV². Healthy mean must be 2, all-channel mean 1.5.
        let frame = TestFrames.frame(
            at: 0,
            tp9: TestFrames.powers(alpha: 100),
            af7: TestFrames.powers(alpha: 1),
            af8: TestFrames.powers(alpha: 100),
            tp10: TestFrames.powers(alpha: 100),
            health: TestFrames.health(af7: .dead)
        )
        let feature = BiofeedbackFeature.bandAbsolute(.alpha, channel: nil)
        XCTAssertEqual(feature.evaluate(in: frame, healthyOnly: true) ?? -99, 2, accuracy: 1e-6)
        XCTAssertEqual(feature.evaluate(in: frame, healthyOnly: false) ?? -99, 1.5, accuracy: 1e-6)
    }

    func testAveragedFallsBackToAllChannelsWhenNoneHealthy() {
        let frame = TestFrames.frame(
            at: 0,
            tp9: TestFrames.powers(alpha: 100),
            af7: TestFrames.powers(alpha: 1),
            af8: TestFrames.powers(alpha: 100),
            tp10: TestFrames.powers(alpha: 100),
            health: [.tp9: .dead, .af7: .dead, .af8: .saturated, .tp10: .stale]
        )
        let feature = BiofeedbackFeature.bandAbsolute(.alpha, channel: nil)
        XCTAssertEqual(feature.evaluate(in: frame, healthyOnly: true) ?? -99, 1.5, accuracy: 1e-6)
        XCTAssertFalse(feature.isHealthy(in: frame))
    }

    func testRelativeAndRatio() {
        let frame = TestFrames.frame(at: 0, tp9: TestFrames.powers(alpha: 40, beta: 10, theta: 30, delta: 10, gamma: 10))
        XCTAssertEqual(BiofeedbackFeature.bandRelative(.alpha, channel: .tp9).evaluate(in: frame) ?? -1, 0.4, accuracy: 1e-6)
        XCTAssertEqual(BiofeedbackFeature.bandRatio(numerator: .theta, denominator: .beta, channel: .tp9).evaluate(in: frame) ?? -1, 3, accuracy: 1e-6)
    }

    func testRatioWithZeroDenominatorIsNil() {
        let frame = TestFrames.frame(at: 0, tp9: TestFrames.powers(alpha: 40, beta: 0))
        XCTAssertNil(BiofeedbackFeature.bandRatio(numerator: .alpha, denominator: .beta, channel: .tp9).evaluate(in: frame))
    }

    func testChannelQualityEncoding() {
        let cases: [(ChannelHealthStatus, Float)] = [(.healthy, 1), (.unknown, 0.5), (.saturated, 0), (.dead, 0), (.stale, 0)]
        for (status, expected) in cases {
            let frame = TestFrames.frame(at: 0, health: TestFrames.health(af7: status))
            XCTAssertEqual(BiofeedbackFeature.channelQuality(.af7).evaluate(in: frame), expected, "\(status)")
        }
        // A channel missing from the health dictionary reads as unknown.
        let frame = TestFrames.frame(at: 0, health: [:])
        XCTAssertEqual(BiofeedbackFeature.channelQuality(.tp9).evaluate(in: frame), 0.5)
    }

    func testEventsAndIMU() {
        let accel = MovementSample(timestamp: 0, kind: .accel, x: 0.1, y: -0.2, z: 0.98)
        let frame = TestFrames.frame(at: 0, blink: true, accel: accel)
        XCTAssertEqual(BiofeedbackFeature.blink.evaluate(in: frame), 1)
        XCTAssertEqual(BiofeedbackFeature.jawClench.evaluate(in: frame), 0)
        XCTAssertEqual(BiofeedbackFeature.accel(.z).evaluate(in: frame), 0.98)
        XCTAssertNil(BiofeedbackFeature.gyro(.x).evaluate(in: frame))
        XCTAssertTrue(BiofeedbackFeature.blink.isHealthy(in: frame))
        XCTAssertTrue(BiofeedbackFeature.accel(.x).requiredChannels.isEmpty)
    }

    func testHealthGateSemantics() {
        let frame = TestFrames.frame(at: 0, health: TestFrames.health(af7: .saturated))
        XCTAssertFalse(BiofeedbackFeature.bandAbsolute(.alpha, channel: .af7).isHealthy(in: frame))
        XCTAssertTrue(BiofeedbackFeature.bandAbsolute(.alpha, channel: .tp9).isHealthy(in: frame))
        XCTAssertTrue(BiofeedbackFeature.bandAbsolute(.alpha, channel: nil).isHealthy(in: frame), "one healthy channel is enough for an average")
        XCTAssertEqual(BiofeedbackFeature.bandAbsolute(.alpha, channel: .af7).requiredChannels, [.af7])
        XCTAssertEqual(BiofeedbackFeature.bandAbsolute(.alpha, channel: nil).requiredChannels, Set(EEGChannel.allCases))
    }

    func testFeatureIsCodableRoundTrip() throws {
        let features: [BiofeedbackFeature] = [
            .bandAbsolute(.alpha, channel: .tp9),
            .bandAbsolute(.beta, channel: nil),
            .bandRatio(numerator: .theta, denominator: .beta, channel: .af8),
            .channelQuality(.tp10),
            .blink, .jawClench, .accel(.y), .gyro(.z),
        ]
        let data = try JSONEncoder().encode(features)
        let decoded = try JSONDecoder().decode([BiofeedbackFeature].self, from: data)
        XCTAssertEqual(decoded, features)
    }

    func testFrameFromWindowDerivesEventsFromIntent() {
        let window = EEGWindow(samples: [[Float]](repeating: [Float](repeating: 0, count: 256), count: 4), sampleRate: 256, endTimestamp: 3.5, sequence: 9)
        let health = EEGChannel.allCases.map { ChannelHealthState(channel: $0, status: .healthy, rms: 10, samples: 256, timestamp: 3.5) }
        let blink = BiofeedbackFrame(window: window, health: health, intent: .doubleBlink)
        XCTAssertTrue(blink.blink)
        XCTAssertFalse(blink.jawClench)
        XCTAssertEqual(blink.timestamp, 3.5)
        XCTAssertEqual(blink.healthyChannels, EEGChannel.allCases)
        let clench = BiofeedbackFrame(window: window, health: health, intent: .jawClench)
        XCTAssertTrue(clench.jawClench)
        let rest = BiofeedbackFrame(window: window, health: health, intent: .rest)
        XCTAssertFalse(rest.blink || rest.jawClench)
    }
}
