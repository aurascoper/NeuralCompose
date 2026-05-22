import XCTest
@testable import BCICore

final class RingBufferTests: XCTestCase {

    func testEmpty() {
        let b = EEGRingBuffer(capacity: 8)
        XCTAssertEqual(b.count, 0)
        XCTAssertTrue(b.snapshot(latest: 4).isEmpty)
    }

    func testAppendUnderCapacity() {
        var b = EEGRingBuffer(capacity: 8)
        for i in 0..<5 {
            b.append(EEGSample(timestamp: Double(i), channels: [Float(i)]))
        }
        XCTAssertEqual(b.count, 5)
        let snap = b.snapshot(latest: 3)
        XCTAssertEqual(snap.map { Int($0.timestamp) }, [2, 3, 4])
    }

    func testWrapAround() {
        var b = EEGRingBuffer(capacity: 4)
        for i in 0..<10 {
            b.append(EEGSample(timestamp: Double(i), channels: [Float(i)]))
        }
        XCTAssertEqual(b.count, 4)
        XCTAssertEqual(b.totalAppends, 10)
        let snap = b.snapshot(latest: 4)
        XCTAssertEqual(snap.map { Int($0.timestamp) }, [6, 7, 8, 9])
    }

    func testSnapshotLargerThanContents() {
        var b = EEGRingBuffer(capacity: 8)
        for i in 0..<3 {
            b.append(EEGSample(timestamp: Double(i), channels: [Float(i)]))
        }
        let snap = b.snapshot(latest: 10)
        XCTAssertEqual(snap.count, 3)
    }

    func testClear() {
        var b = EEGRingBuffer(capacity: 4)
        for i in 0..<5 {
            b.append(EEGSample(timestamp: Double(i), channels: [Float(i)]))
        }
        b.clear()
        XCTAssertEqual(b.count, 0)
        XCTAssertEqual(b.totalAppends, 0)
        XCTAssertTrue(b.snapshot(latest: 4).isEmpty)
    }
}
