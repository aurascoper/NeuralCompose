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

    func testCoreMLMakeMultiArraySubtractsPerChannelDCMeanAndZeroesNonFinite() throws {
        // Channel 0: +820 uV DC offset + alternating +20 / -20 uV AC -> demeaned to +20 / -20
        // Channel 1: +790 uV DC offset + alternating +10 / -10 uV AC + one NaN -> demeaned to +10 / -10, NaN -> 0
        let ch0: [Float] = (0..<8).map { i in 820.0 + ((i % 2 == 0) ? 20.0 : -20.0) }
        var ch1: [Float] = (0..<9).map { i in 790.0 + ((i % 2 == 0) ? 10.0 : -10.0) }
        ch1[8] = .nan // 4 pairs of (+10, -10) average to 790.0 over the 8 finite samples
        let ch2 = Array(repeating: Float(810.0), count: 8)
        let ch3 = Array(repeating: Float(805.0), count: 8)

        let window = EEGWindow(
            samples: [ch0, ch1, ch2, ch3],
            sampleRate: 256,
            endTimestamp: 1.0,
            sequence: 1
        )
        let array = try CoreMLIntentClassifier.makeMultiArray(
            from: window,
            expectedChannels: 4,
            expectedSamples: 12
        )
        let ptr = array.dataPointer.assumingMemoryBound(to: Float32.self)
        for s in 0..<8 {
            let expected0: Float = (s % 2 == 0) ? 20.0 : -20.0
            XCTAssertEqual(ptr[0 * 12 + s], expected0, accuracy: 1e-4)
        }
        // Tail samples (8..<12) on ch0 are zero-padded.
        for s in 8..<12 {
            XCTAssertEqual(ptr[0 * 12 + s], 0.0, accuracy: 1e-6)
        }
        // Ch1 finite samples are demeaned to +/-10, and the NaN at index 8 becomes 0.
        for s in 0..<8 {
            let expected1: Float = (s % 2 == 0) ? 10.0 : -10.0
            XCTAssertEqual(ptr[1 * 12 + s], expected1, accuracy: 1e-4)
        }
        XCTAssertEqual(ptr[1 * 12 + 8], 0.0, accuracy: 1e-6)
        // Flat DC channels demean to 0.0.
        for s in 0..<12 {
            XCTAssertEqual(ptr[2 * 12 + s], 0.0, accuracy: 1e-6)
            XCTAssertEqual(ptr[3 * 12 + s], 0.0, accuracy: 1e-6)
        }
    }
}
