import XCTest
@testable import BCICore

final class BoundedAsyncChannelTests: XCTestCase {

    func testDeliversInOrder() async {
        let ch = BoundedAsyncChannel<Int>(capacity: 8, overflow: .dropOldest)
        for i in 0..<5 { _ = ch.send(i) }
        ch.finish()
        var received: [Int] = []
        for await v in ch.stream { received.append(v) }
        XCTAssertEqual(received, [0, 1, 2, 3, 4])
    }

    func testDropOldestUnderPressure() async {
        // Drain consumer slowly; producer overruns.
        let ch = BoundedAsyncChannel<Int>(capacity: 2, overflow: .dropOldest)
        for i in 0..<10 { _ = ch.send(i) }
        ch.finish()
        var received: [Int] = []
        for await v in ch.stream { received.append(v) }
        XCTAssertEqual(received.count, 2)
        XCTAssertEqual(received.last, 9)   // most-recent retained
    }

    func testFinishedChannelRejectsNewSend() async {
        let ch = BoundedAsyncChannel<Int>(capacity: 4)
        ch.finish()
        // The yield may report `terminated` — we treat that as not enqueued.
        let ok = ch.send(99)
        XCTAssertFalse(ok)
    }

    /// Validates the pattern `AppViewModel` uses to fan raw samples out
    /// to visualization consumers: a single `BoundedAsyncChannel<EEGSample>`
    /// whose `stream` is handed to multiple consumers. Each consumer must
    /// see every sample in order, and a single `finish()` must terminate
    /// every consumer.
    func testEEGSampleFanOut() async {
        let ch = BoundedAsyncChannel<EEGSample>(capacity: 8, overflow: .dropOldest)

        // Two consumers reading from the same channel. AsyncStream values
        // are single-iteration, so we capture the streams first and then
        // iterate each in its own task.
        let s1 = ch.stream
        let s2 = ch.stream

        async let received1: [EEGSample] = {
            var out: [EEGSample] = []
            for await s in s1 { out.append(s) }
            return out
        }()
        async let received2: [EEGSample] = {
            var out: [EEGSample] = []
            for await s in s2 { out.append(s) }
            return out
        }()

        // Yield a handful of samples. The order must be preserved on both
        // consumers.
        let produced: [EEGSample] = (0..<5).map { i in
            EEGSample(timestamp: TimeInterval(i), channels: [Float(i), Float(-i)])
        }
        for s in produced { _ = ch.send(s) }
        ch.finish()

        let (r1, r2) = await (received1, received2)
        XCTAssertEqual(r1, produced)
        XCTAssertEqual(r2, produced)
    }
}
