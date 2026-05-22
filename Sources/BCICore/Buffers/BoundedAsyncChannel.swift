import Foundation

/// Result of a `send()` call. Distinguishes between successful enqueueing,
/// buffer overflow (older element dropped), and channel termination.
public struct BoundedAsyncChannelSendResult: Sendable {
    public let accepted: Bool
    public let droppedBufferedElement: Bool
    public let terminated: Bool
}

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
    @discardableResult
    public func send(_ element: Element) -> BoundedAsyncChannelSendResult {
        switch continuation.yield(element) {
        case .enqueued:
            return BoundedAsyncChannelSendResult(accepted: true, droppedBufferedElement: false, terminated: false)
        case .dropped:
            return BoundedAsyncChannelSendResult(accepted: true, droppedBufferedElement: true, terminated: false)
        case .terminated:
            return BoundedAsyncChannelSendResult(accepted: false, droppedBufferedElement: false, terminated: true)
        @unknown default:
            return BoundedAsyncChannelSendResult(accepted: false, droppedBufferedElement: false, terminated: false)
        }
    }

    public func finish() {
        continuation.finish()
    }
}
