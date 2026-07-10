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
        let result = ch.send(99)
        XCTAssertFalse(result.accepted)
        XCTAssertTrue(result.terminated)
    }

    /// Documents `BoundedAsyncChannel`'s single-consumer semantics.
    ///
    /// `BoundedAsyncChannel` is a queue, NOT a broadcast channel: its one
    /// `AsyncStream` delivers each element to exactly one iterator. Two
    /// concurrent consumers of the same `stream` therefore *split* the
    /// elements — together they see the full set with no duplication, but
    /// neither sees all of it. The raw-`EEGSample` fan-out that needs every
    /// consumer to see every sample uses `AsyncMulticastChannel` instead
    /// (see `AsyncMulticastChannelTests`).
    func testTwoConsumersSplitTheStream() async {
        let ch = BoundedAsyncChannel<EEGSample>(capacity: 16, overflow: .dropOldest)

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

        let produced: [EEGSample] = (0..<10).map { i in
            EEGSample(timestamp: TimeInterval(i), channels: [Float(i), Float(-i)])
        }
        for s in produced { _ = ch.send(s) }
        ch.finish()

        let (r1, r2) = await (received1, received2)
        // Each element is delivered exactly once, to exactly one consumer:
        // the union is the produced set and the counts sum without overlap.
        XCTAssertEqual(r1.count + r2.count, produced.count)
        XCTAssertEqual(Set(r1 + r2), Set(produced))
        XCTAssertTrue(Set(r1).isDisjoint(with: Set(r2)))
    }
}
