import Foundation

/// Runs `operation`, returning its value — or `nil` if it does not finish within
/// `seconds`, **abandoning** the operation rather than waiting for it.
///
/// This deliberately does NOT use `withThrowingTaskGroup`: a structured task
/// group waits for every child to finish at its scope exit, so if the operation
/// is a blocking, non-cooperative call (a hung in-process Metal/MLX load that
/// ignores `Task.cancel()`), the group — and thus the caller — would hang forever
/// even after the timeout fired. Instead it races two *detached* tasks through a
/// first-wins continuation; on timeout the load task is simply left to leak
/// (one stuck thread) while the caller proceeds. Guarding `makeDefault()` this
/// way means a wedged backend load can never wedge app startup.
public func withAbandoningTimeout<T: Sendable>(
    seconds: Double,
    operation: @escaping @Sendable () async -> T
) async -> T? {
    let once = TimeoutOnceFlag()
    return await withCheckedContinuation { (cont: CheckedContinuation<T?, Never>) in
        Task.detached {
            let value = await operation()
            if once.claim() { cont.resume(returning: value) }
        }
        Task.detached {
            try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
            if once.claim() { cont.resume(returning: nil) }
        }
    }
}

/// Thread-safe "exactly one caller wins" flag, so the load and the timeout can
/// race to resume the continuation without a double-resume.
final class TimeoutOnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false
    /// Returns `true` for the first caller only; `false` for every caller after.
    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}
