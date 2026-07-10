import XCTest
@testable import BCICore

final class ChannelHealthThresholdsTests: XCTestCase {

    // MARK: - status(forRMS:samples:)

    func testDefaultThresholdsClassifyHealthyRange() {
        // The default healthy range is [2, 200) µV. Sample count is
        // well above the 32-sample minimum, so we should get the
        // straight RMS-based classification.
        XCTAssertEqual(
            ChannelHealthThresholds.default.status(forRMS: 10, samples: 256),
            .healthy
        )
        XCTAssertEqual(
            ChannelHealthThresholds.default.status(forRMS: 50, samples: 256),
            .healthy
        )
        XCTAssertEqual(
            ChannelHealthThresholds.default.status(forRMS: 199, samples: 256),
            .healthy
        )
    }

    func testDefaultThresholdsClassifySaturated() {
        // Anything above 200 µV with sufficient samples is saturated.
        XCTAssertEqual(
            ChannelHealthThresholds.default.status(forRMS: 201, samples: 256),
            .saturated
        )
        XCTAssertEqual(
            ChannelHealthThresholds.default.status(forRMS: 900, samples: 256),
            .saturated
        )
    }

    func testDefaultThresholdsClassifyDead() {
        // Below 2 µV with sufficient samples is dead.
        XCTAssertEqual(
            ChannelHealthThresholds.default.status(forRMS: 0, samples: 256),
            .dead
        )
        XCTAssertEqual(
            ChannelHealthThresholds.default.status(forRMS: 1.99, samples: 256),
            .dead
        )
    }

    func testDefaultThresholdsClassifyUnknownBelowMinimumSamples() {
        // Below the 32-sample floor, the classifier returns .unknown
        // regardless of the RMS value, because very short windows
        // are dominated by a single oscillation.
        XCTAssertEqual(
            ChannelHealthThresholds.default.status(forRMS: 10, samples: 0),
            .unknown
        )
        XCTAssertEqual(
            ChannelHealthThresholds.default.status(forRMS: 10, samples: 31),
            .unknown
        )
        // At exactly the minimum we should still get the real
        // classification; the floor is inclusive.
        XCTAssertEqual(
            ChannelHealthThresholds.default.status(forRMS: 10, samples: 32),
            .healthy
        )
    }

    func testCustomThresholdsCanBeConstructed() {
        // Tighter dead threshold; looser saturation cutoff.
        let t = ChannelHealthThresholds(
            deadRMS: 5,
            saturatedRMS: 500,
            minimumSamples: 64
        )
        XCTAssertEqual(t.status(forRMS: 3, samples: 256), .dead)
        XCTAssertEqual(t.status(forRMS: 50, samples: 256), .healthy)
        XCTAssertEqual(t.status(forRMS: 600, samples: 256), .saturated)
        XCTAssertEqual(t.status(forRMS: 50, samples: 32), .unknown)
        XCTAssertEqual(t.status(forRMS: 50, samples: 64), .healthy)
    }

    // MARK: - Sendable / Equatable

    func testThresholdsAreSendableAndEquatable() {
        let a = ChannelHealthThresholds.default
        let b = ChannelHealthThresholds.default
        XCTAssertEqual(a, b)
        // The static `.default` must always be the same value, by
        // construction. If someone replaces it with a non-default
        // in the future this test should fail loudly.
        XCTAssertEqual(a.deadRMS, 2)
        XCTAssertEqual(a.saturatedRMS, 200)
        XCTAssertEqual(a.minimumSamples, 32)
    }
}
