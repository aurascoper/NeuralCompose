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
}
