import Foundation

/// Fixed-capacity reader/writer ring for JEPA feature states.
///
/// The storage is allocated exactly once, and each append replaces one slot
/// in O(1) time. Reads reconstruct a chronological copy only after the first
/// complete window has arrived; partial windows are never eligible for a
/// training transition.
public final class JEPASpectralStateRingBuffer: @unchecked Sendable {
    private var storage: [JEPASpectralState?]
    public let capacity: Int
    private var writeIndex = 0
    private var isFull = false

    /// Multiple snapshots may proceed together. An append uses a barrier so
    /// no reader can observe a partially-overwritten slot.
    private let queue = DispatchQueue(
        label: "com.neuralcompose.jepa-spectral-state-buffer",
        attributes: .concurrent
    )

    public init(capacity: Int) {
        precondition(capacity > 0, "JEPASpectralStateRingBuffer capacity must be > 0")
        self.capacity = capacity
        self.storage = Array(repeating: nil, count: capacity)
    }

    /// Called from the EEG processing path. This does not shift or grow the
    /// backing array.
    public func append(_ state: JEPASpectralState) {
        queue.async(flags: .barrier) {
            self.storage[self.writeIndex] = state
            self.writeIndex = (self.writeIndex + 1) % self.capacity
            if self.writeIndex == 0 {
                self.isFull = true
            }
        }
    }

    /// Returns the whole buffer in oldest-to-newest order, or `nil` while the
    /// initial window is still warming up.
    public func snapshot() -> [JEPASpectralState]? {
        queue.sync {
            guard isFull else { return nil }

            var result: [JEPASpectralState] = []
            result.reserveCapacity(capacity)
            for offset in 0..<capacity {
                let index = (writeIndex + offset) % capacity
                guard let state = storage[index] else { return nil }
                result.append(state)
            }
            return result
        }
    }

    /// Discards all buffered states and resets to the pre-warmup state.
    /// `isFull` was previously a one-way latch that never reset, so toggling
    /// capture off and back on could return stale, pre-toggle-off contents
    /// as if they were a freshly-completed window — splicing unrelated
    /// chronological data into one persisted transition. Callers must call
    /// this on every capture-enable transition (see
    /// `TransitionCaptureManager.clear()`), not just at construction.
    public func clear() {
        queue.async(flags: .barrier) {
            self.storage = Array(repeating: nil, count: self.capacity)
            self.writeIndex = 0
            self.isFull = false
        }
    }
}
