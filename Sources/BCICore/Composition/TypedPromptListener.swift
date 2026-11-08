import Foundation

/// A `HypnagogicListening` conformer fed by typed text instead of the
/// microphone. The loop calls `listen(timeout:)` exactly as it does with the
/// mic listener; this actor hands back the next submitted line, or suspends
/// until one arrives. Lines are delivered first-in first-out, whitespace-only
/// submissions are dropped, and `cancel()` resumes every suspended `listen`
/// with `nil` (the loop reads `nil` as silence).
///
/// Why a pull model: the loop owns the turn cadence (listen, generate, speak)
/// and must never be interrupted mid-utterance by a new prompt. Queuing here
/// keeps the loop's control flow untouched; a prompt typed while the loop is
/// speaking waits for the next listen turn.
///
/// `timeout` is intentionally ignored. The mic listener returns `nil` after a
/// silent window so the loop can breathe an induction cue; a typing user is
/// not silent, only slow, and a cue every few seconds while they compose a
/// sentence would be noise. The loop idles on the suspended `listen` instead.
///
/// No microphone, no speech recognizer and no OS permission are involved, so
/// `requestAuthorization()` always succeeds and `isLive` is `false`.
public actor TypedPromptListener: HypnagogicListening {
    nonisolated public let isLive = false

    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<String?, any Error>
    }

    private var pending: [String]
    private var waiters: [Waiter] = []

    /// `seed` lines are queued in order before any `submit(_:)`; blank lines
    /// are dropped the same way submitted ones are.
    public init(seed: [String] = []) {
        self.pending = seed.compactMap(Self.normalized)
    }

    public func requestAuthorization() async -> Bool { true }

    /// Queues one prompt. Delivered to a suspended `listen` immediately when
    /// one is waiting, otherwise held until the next `listen` call. A
    /// whitespace-only `text` is ignored.
    public func submit(_ text: String) {
        guard let line = Self.normalized(text) else { return }
        if waiters.isEmpty {
            pending.append(line)
        } else {
            let waiter = waiters.removeFirst()
            waiter.continuation.resume(returning: line)
        }
    }

    /// `submit(_:)` for each element, in order.
    public func submitAll(_ texts: [String]) {
        for text in texts { submit(text) }
    }

    /// Lines queued and not yet handed to a `listen` call.
    public func pendingCount() -> Int { pending.count }

    /// Returns the next queued line, or suspends until `submit(_:)` provides
    /// one. Resumes with `nil` on `cancel()` or when the awaiting task is
    /// cancelled.
    public func listen(timeout: TimeInterval) async throws -> String? {
        if !pending.isEmpty { return pending.removeFirst() }
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String?, any Error>) in
                waiters.append(Waiter(id: id, continuation: continuation))
            }
        } onCancel: {
            Task { await self.resumeWaiter(id: id) }
        }
    }

    /// Resumes every suspended `listen` with `nil`. Queued lines are kept, so
    /// a loop rebuilt after a stop still receives them.
    public func cancel() {
        let suspended = waiters
        waiters.removeAll()
        for waiter in suspended {
            waiter.continuation.resume(returning: nil)
        }
    }

    private func resumeWaiter(id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = waiters.remove(at: index)
        waiter.continuation.resume(returning: nil)
    }

    private static func normalized(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - Seed files

    /// Parses the contents of a seed file into prompt lines: one prompt per
    /// line, trimmed; blank lines and lines whose first non-blank character
    /// is `#` are skipped. Shared by `dialectic-session --seed-file` and any
    /// other scripted feeder, and kept here (not in the executable target) so
    /// it is unit-testable.
    public static func parseSeedLines(_ contents: String) -> [String] {
        contents
            .split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }
}
