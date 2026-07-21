import XCTest
@testable import BCILLM

final class AsyncTimeoutTests: XCTestCase {

    func testFastOperationReturnsItsValue() async {
        let r = await withAbandoningTimeout(seconds: 5) { () -> Int in 42 }
        XCTAssertEqual(r, 42)
    }

    func testSlowOperationTimesOutToNil() async {
        let r = await withAbandoningTimeout(seconds: 0.1) { () -> Int in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            return 42
        }
        XCTAssertNil(r, "an operation exceeding the timeout is abandoned -> nil")
    }

    func testReturnsPromptlyOnTimeoutRatherThanWaitingForTheOperation() async {
        let start = Date()
        let r = await withAbandoningTimeout(seconds: 0.2) { () -> Int in
            try? await Task.sleep(nanoseconds: 10_000_000_000)  // 10s "hang"
            return 1
        }
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertNil(r)
        XCTAssertLessThan(elapsed, 3.0,
                          "returns near the timeout, not after the full (abandoned) operation")
    }

    func testFirstWinsIsSingleResume() async {
        // A load that finishes just under the timeout must return its value, not
        // race into a double-resume with the timer.
        let r = await withAbandoningTimeout(seconds: 1.0) { () -> String in
            try? await Task.sleep(nanoseconds: 50_000_000)  // 0.05s < 1s
            return "ok"
        }
        XCTAssertEqual(r, "ok")
    }
}
