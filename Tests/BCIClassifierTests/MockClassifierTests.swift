import XCTest
@testable import BCICore
@testable import BCIClassifier

final class MockClassifierTests: XCTestCase {

    func testRestForLowEnergy() async throws {
        let c = MockIntentClassifier()
        let win = EEGWindow(
            samples: Array(repeating: Array(repeating: Float(0.01), count: 256), count: 4),
            sampleRate: 256,
            endTimestamp: 0,
            sequence: 0
        )
        let p = try await c.classify(window: win)
        XCTAssertEqual(p.intent, .rest)
    }

    func testJawClenchForHighRMS() async throws {
        let c = MockIntentClassifier(config: .init(clenchThreshold: 5, selectThreshold: 50, blinkAlphaThreshold: 100))
        // Big random signal: high RMS, low EMG/alpha relative to thresholds.
        let bigChannel: [Float] = (0..<256).map { _ in Float.random(in: -20...20) }
        let win = EEGWindow(
            samples: Array(repeating: bigChannel, count: 4),
            sampleRate: 256,
            endTimestamp: 0,
            sequence: 0
        )
        let p = try await c.classify(window: win)
        XCTAssertTrue(p.intent == .jawClench || p.intent == .select)
    }
}
