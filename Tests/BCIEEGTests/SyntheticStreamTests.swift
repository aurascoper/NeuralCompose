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
        // Collect inside the task and return the results, rather than
        // mutating captured `var`s from a concurrently-executing closure
        // (a Swift 6 strict-concurrency data race).
        let collectTask = Task { () -> (count: Int, firstChannelCount: Int) in
            var count = 0
            var firstChannelCount = 0
            for try await sample in stream {
                if firstChannelCount == 0 { firstChannelCount = sample.channels.count }
                count += 1
                if count >= 50 { break }
            }
            return (count, firstChannelCount)
        }
        let result = (try? await collectTask.value) ?? (count: 0, firstChannelCount: 0)
        await s.stop()
        XCTAssertEqual(result.firstChannelCount, 4)
        XCTAssertGreaterThanOrEqual(result.count, 50)
    }

    func testFactoryFallsBackForMuseWhenBridgeUnavailable() {
        for profile: MuseBoardProfile in [.museTwoNativeBLE, .museTwoBLED,
                                          .museSNativeBLE,   .museSBLED,
                                          .museSAthena] {
            let r = EEGStreamFactory.make(profile: profile)
            // With BCI_BRIDGE_STUB (default), we should *not* get the
            // BrainFlow service — we should fall back to synthetic.
            XCTAssertEqual(r.acquisition, .synthetic, "profile \(profile)")
            XCTAssertEqual(r.transport, .none, "profile \(profile)")
            XCTAssertEqual(r.profile, .synthetic, "profile \(profile)")
        }
    }
}
