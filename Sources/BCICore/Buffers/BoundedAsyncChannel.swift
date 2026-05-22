import Foundation

/// Bounded async channel for moving a stream of `Sendable` values from one
/// concurrency domain to another, with strict backpressure: if the consumer
/// can't keep up, the producer either drops the oldest element (`.dropOldest`)
/// or drops the newest (`.dropNewest`).
///
/// We never block the EEG-acquisition task — dropping samples on the rare
/// occasion the UI stutters is preferable to stalling BrainFlow's read loop.
///
/// This is a wrapper around `AsyncStream.makeStream(...)` with explicit
/// buffering policy and a stable closing semantic.
public struct BoundedAsyncChannel<Element: Sendable>: Sendable {

    public enum OverflowPolicy: Sendable {
        case dropOldest
        case dropNewest
    }

    public let stream: AsyncStream<Element>
    public let continuation: AsyncStream<Element>.Continuation

    public init(capacity: Int, overflow: OverflowPolicy = .dropOldest) {
        precondition(capacity > 0, "channel capacity must be > 0")
        let bufferingPolicy: AsyncStream<Element>.Continuation.BufferingPolicy
        switch overflow {
        case .dropOldest:
            bufferingPolicy = .bufferingOldest(capacity)
        case .dropNewest:
            bufferingPolicy = .bufferingNewest(capacity)
        }
        let (s, c) = AsyncStream.makeStream(of: Element.self, bufferingPolicy: bufferingPolicy)
        self.stream = s
        self.continuation = c
    }

    /// Push an element. Will drop per overflow policy if the buffer is full.
    /// Returns `false` if the channel has been finished and the value was
    /// dropped on the floor.
    @discardableResult
    public func send(_ element: Element) -> Bool {
        switch continuation.yield(element) {
        case .enqueued, .dropped: return true
        case .terminated:         return false
        @unknown default:         return false
        }
    }

    public func finish() {
        continuation.finish()
    }
}
