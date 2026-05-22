import XCTest
@testable import BCICore

final class EEGWindowingTests: XCTestCase {

    func testEmitsAfterEnoughSamples() async throws {
        let cfg = EEGWindowingConfig(
            windowSeconds: 1.0,
            strideSeconds: 1.0,
            sampleRate: 16.0,
            channelCount: 2
        )
        let w = EEGWindowing(config: cfg)
        var emitted: [EEGWindow] = []
        for i in 0..<32 {
            let s = EEGSample(timestamp: Double(i) / 16.0, channels: [Float(i), Float(-i)])
            if let win = try await w.ingest(s) { emitted.append(win) }
        }
        XCTAssertGreaterThanOrEqual(emitted.count, 2)
        XCTAssertEqual(emitted[0].channelCount, 2)
        XCTAssertEqual(emitted[0].sampleCount, 16)
        // Sequence numbers monotonic
        for i in 1..<emitted.count {
            XCTAssertEqual(emitted[i].sequence, emitted[i-1].sequence + 1)
        }
    }

    func testChannelMismatchThrows() async {
        let cfg = EEGWindowingConfig(sampleRate: 16, channelCount: 4)
        let w = EEGWindowing(config: cfg)
        do {
            _ = try await w.ingest(EEGSample(timestamp: 0, channels: [1, 2, 3])) // 3 vs 4
            XCTFail("expected channel mismatch")
        } catch let e as BCIError {
            if case .channelShapeMismatch(let exp, let act) = e {
                XCTAssertEqual(exp, 4); XCTAssertEqual(act, 3)
            } else {
                XCTFail("wrong error: \(e)")
            }
        } catch {
            XCTFail("wrong error: \(error)")
        }
    }
}
