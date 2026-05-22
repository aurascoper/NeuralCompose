import XCTest
@testable import BCICore
@testable import BCIEEG

final class SyntheticStreamTests: XCTestCase {

    func testEmitsExpectedShape() async throws {
        let s = SyntheticEEGStream(config: .init(
            channelCount: 4,
            sampleRate: 256,
            amplitude: 2.0,
            alphaFrequencyHz: 10,
            enableDemoBursts: false
        ))
        let stream = try await s.start()
        var count = 0
        var firstChannelCount: Int = 0
        let collectTask = Task {
            for try await sample in stream {
                if firstChannelCount == 0 { firstChannelCount = sample.channels.count }
                count += 1
                if count >= 50 { break }
            }
        }
        _ = try? await collectTask.value
        await s.stop()
        XCTAssertEqual(firstChannelCount, 4)
        XCTAssertGreaterThanOrEqual(count, 50)
    }

    func testFactoryFallsBackForMuseWhenBridgeUnavailable() {
        for profile: MuseBoardProfile in [.museTwoNativeBLE, .museTwoBLED,
                                          .museSNativeBLE,   .museSBLED,
                                          .museSAthena] {
            let r = EEGStreamFactory.make(profile: profile)
            // With BCI_BRIDGE_STUB (default), we should *not* get the
            // BrainFlow service — we should fall back to synthetic.
            XCTAssertEqual(r.source, .synthetic, "profile \(profile)")
            XCTAssertEqual(r.profile, .synthetic, "profile \(profile)")
        }
    }
}
