import XCTest
@testable import BCICore

/// Contract for the raw-`EEGSample` broadcast fan-out. This is the behavior
/// `AppViewModel.liveSampleStream()` depends on: two independent subscribers
/// (the plotter and the channel-health provider) must EACH receive every
/// sample, not race for a split of one shared stream.
final class AsyncMulticastChannelTests: XCTestCase {

    /// Two subscribers each receive the full sequence, in order.
    func testEachSubscriberReceivesEverySample() async {
        let ch = AsyncMulticastChannel<Int>(capacity: 16, overflow: .dropOldest)
        let a = ch.subscribe()
        let b = ch.subscribe()

        async let ra: [Int] = collect(a)
        async let rb: [Int] = collect(b)

        // Give both drain tasks a moment to begin iterating before we finish.
        for i in 0..<8 { _ = ch.send(i) }
        // Small yield so the buffered elements are observed; then close.
        await Task.yield()
        ch.finish()

        let (gotA, gotB) = await (ra, rb)
        XCTAssertEqual(gotA, Array(0..<8))
        XCTAssertEqual(gotB, Array(0..<8))
    }

    /// Cancelling one subscriber must not affect the other, and the dropped
    /// subscriber must be de-registered.
    func testCancellingOneSubscriberLeavesTheOther() async {
        let ch = AsyncMulticastChannel<Int>(capacity: 16, overflow: .dropOldest)
        // Register both subscribers synchronously, before any send, so there
        // is no race between subscription and the first element.
        let aStream = ch.subscribe()
        let b = ch.subscribe()
        XCTAssertEqual(ch.subscriberCount, 2)

        // Subscriber A drains a couple of values then stops iterating, which
        // terminates its stream and should de-register its continuation.
        let aTask = Task { () -> Int in
            var count = 0
            for await _ in aStream {
                count += 1
                if count == 2 { break }
            }
            return count
        }

        async let rb: [Int] = collect(b)

        _ = ch.send(0)
        _ = ch.send(1)
        _ = await aTask.value          // A has terminated its stream

        // Its continuation should have been removed; only B remains.
        // (Poll briefly: onTermination runs asynchronously.)
        await waitUntil { ch.subscriberCount == 1 }
        XCTAssertEqual(ch.subscriberCount, 1)

        _ = ch.send(2)
        await Task.yield()
        ch.finish()

        let gotB = await rb
        XCTAssertEqual(gotB, [0, 1, 2])   // B saw everything, uninterrupted
    }

    /// Subscribing after `finish()` yields an already-finished stream.
    func testSubscribeAfterFinishIsEmpty() async {
        let ch = AsyncMulticastChannel<Int>()
        ch.finish()
        let late = ch.subscribe()
        let got = await collect(late)
        XCTAssertEqual(got, [])
        XCTAssertEqual(ch.subscriberCount, 0)
    }

}

// MARK: - Helpers
//
// Free functions, not methods: `async let collect(...)` spawns a child task,
// and an instance method would capture the non-Sendable XCTestCase `self`
// into it — a Swift 6 strict-concurrency error. File-scope functions capture
// only their Sendable arguments.

private func collect<S: AsyncSequence>(_ seq: S) async -> [S.Element] where S.Element: Sendable {
    var out: [S.Element] = []
    do {
        for try await v in seq { out.append(v) }
    } catch {
        // AsyncStream<Element> never throws; ignore for the generic path.
    }
    return out
}

/// Spin briefly until `condition` holds or a short deadline passes.
private func waitUntil(_ condition: @Sendable () -> Bool) async {
    for _ in 0..<100 {
        if condition() { return }
        await Task.yield()
        try? await Task.sleep(nanoseconds: 1_000_000)  // 1 ms
    }
}
