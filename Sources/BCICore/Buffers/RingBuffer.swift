import Foundation

/// Fixed-capacity, value-typed ring buffer specialized to `EEGSample`.
///
/// Optimized for the EEG hot path:
///   • appends in O(1), no allocation after init;
///   • exposes the most recent `n` samples as a copy on demand;
///   • holds a monotonic count so windowing can know whether a new window
///     boundary has crossed without scanning.
///
/// This is *not* a thread-safe primitive on its own. It is intended to live
/// inside the `BoundedAsyncChannel` actor (or inside another actor) which
/// provides isolation. Keeping the type a `struct` lets it be reasoned about
/// as a pure value during snapshots.
public struct EEGRingBuffer: Sendable {
    private var storage: [EEGSample?]
    private var writeIndex: Int = 0
    public private(set) var totalAppends: UInt64 = 0
    public let capacity: Int

    public init(capacity: Int) {
        precondition(capacity > 0, "RingBuffer capacity must be > 0")
        self.capacity = capacity
        self.storage = Array(repeating: nil, count: capacity)
    }

    public var count: Int {
        Int(min(totalAppends, UInt64(capacity)))
    }

    public mutating func append(_ sample: EEGSample) {
        storage[writeIndex] = sample
        writeIndex = (writeIndex &+ 1) % capacity
        totalAppends &+= 1
    }

    /// Snapshot of the most recent `n` samples (chronological order).
    ///
    /// If fewer than `n` have been appended, returns whatever is available.
    public func snapshot(latest n: Int) -> [EEGSample] {
        let available = count
        let want = min(n, available)
        guard want > 0 else { return [] }

        var result: [EEGSample] = []
        result.reserveCapacity(want)
        // Start `want` positions back from writeIndex.
        let start = (writeIndex - want + capacity) % capacity
        for i in 0..<want {
            let idx = (start + i) % capacity
            if let s = storage[idx] {
                result.append(s)
            }
        }
        return result
    }

    public mutating func clear() {
        for i in storage.indices { storage[i] = nil }
        writeIndex = 0
        totalAppends = 0
    }
}
