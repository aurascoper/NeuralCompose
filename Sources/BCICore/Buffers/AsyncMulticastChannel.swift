import Foundation

/// One-producer, many-consumer broadcast channel for `Sendable` values.
///
/// Unlike `BoundedAsyncChannel`, which is a single-consumer queue (its one
/// `AsyncStream` distributes each element to whichever iterator asks first),
/// `AsyncMulticastChannel` hands every subscriber its *own* `AsyncStream` and
/// replicates each `send(_:)` to all live subscribers. This is the primitive
/// the raw-`EEGSample` fan-out needs: the plotter and the channel-health
/// provider must each see the full sample stream, not a race-split half of it.
///
/// Backpressure is per subscriber. Each subscriber's stream has its own
/// bounded buffer (`capacity`, drop-oldest by default), so a slow consumer
/// drops its own oldest samples without stalling the producer or starving
/// the other subscribers. We never block the EEG-acquisition task.
///
/// Subscribers registered after `finish()` receive an already-finished
/// stream. A subscriber whose stream is cancelled or deinitialised is
/// removed automatically via the continuation's termination handler.
///
/// The type is a reference type with an internal lock (`@unchecked Sendable`):
/// `send(_:)`, `subscribe()`, `finish()`, and the termination callbacks may
/// all run on different executors.
public final class AsyncMulticastChannel<Element: Sendable>: @unchecked Sendable {

    public enum OverflowPolicy: Sendable {
        case dropOldest
        case dropNewest
    }

    private let bufferingPolicy: AsyncStream<Element>.Continuation.BufferingPolicy
    private let lock = NSLock()
    private var continuations: [Int: AsyncStream<Element>.Continuation] = [:]
    private var nextID: Int = 0
    private var isFinished = false

    public init(capacity: Int = 8, overflow: OverflowPolicy = .dropOldest) {
        precondition(capacity > 0, "channel capacity must be > 0")
        switch overflow {
        case .dropOldest:
            self.bufferingPolicy = .bufferingOldest(capacity)
        case .dropNewest:
            self.bufferingPolicy = .bufferingNewest(capacity)
        }
    }

    /// Register a new subscriber and return its private stream. Each call
    /// returns a distinct `AsyncStream`; every live subscriber receives every
    /// element passed to `send(_:)` after it subscribed. If the channel is
    /// already finished, the returned stream is finished immediately.
    public func subscribe() -> AsyncStream<Element> {
        AsyncStream(Element.self, bufferingPolicy: bufferingPolicy) { continuation in
            self.lock.lock()
            if self.isFinished {
                self.lock.unlock()
                continuation.finish()
                return
            }
            let id = self.nextID
            self.nextID += 1
            self.continuations[id] = continuation
            self.lock.unlock()

            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.lock()
                self.continuations[id] = nil
                self.lock.unlock()
            }
        }
    }

    /// Broadcast an element to every live subscriber. Returns the number of
    /// subscribers it was delivered to (0 once finished, or with no
    /// subscribers). Each subscriber independently drops per its overflow
    /// policy if its buffer is full.
    @discardableResult
    public func send(_ element: Element) -> Int {
        lock.lock()
        if isFinished {
            lock.unlock()
            return 0
        }
        let active = Array(continuations.values)
        lock.unlock()
        for continuation in active {
            continuation.yield(element)
        }
        return active.count
    }

    /// Terminate the channel and every subscriber's stream. Idempotent.
    public func finish() {
        lock.lock()
        if isFinished {
            lock.unlock()
            return
        }
        isFinished = true
        let active = Array(continuations.values)
        continuations.removeAll()
        lock.unlock()
        for continuation in active {
            continuation.finish()
        }
    }

    /// Number of currently-registered subscribers. Primarily for tests and
    /// diagnostics.
    public var subscriberCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return continuations.count
    }
}
