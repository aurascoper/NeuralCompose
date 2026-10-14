import Foundation
import os

/// The recent exchanges of one conversation, as text: what was heard, and what
/// was voiced in reply.
///
/// The dialectic loop prepends the last few to each voice's prompt, so a
/// follow-up reaches a model that can see what it follows. Before this, each
/// voice saw only the latest utterance: in the Oct 13 log, "reiterate on that
/// framework…" got "don't reiterate the framework at all", because the model
/// had no framework in front of it.
///
/// A reference type so it can outlive a loop instance: the app rebuilds the
/// loop on every mode switch and keeps one of these across rebuilds. It holds
/// only what was heard and what was actually voiced, never the losing
/// candidate and never the Witness's finding, which must not reach the poles.
public final class ConversationHistory: Sendable {
    public struct Exchange: Sendable, Equatable {
        public let heard: String
        /// The words voiced in reply; nil when the turn was silent.
        public let spoken: String?

        public init(heard: String, spoken: String?) {
            self.heard = heard
            self.spoken = spoken
        }
    }

    private let capacity: Int
    private let exchanges = OSAllocatedUnfairLock<[Exchange]>(initialState: [])

    public init(capacity: Int = 16) {
        self.capacity = max(0, capacity)
    }

    public func append(heard: String, spoken: String?) {
        let cap = capacity
        exchanges.withLock { list in
            list.append(Exchange(heard: heard, spoken: spoken))
            if list.count > cap { list.removeFirst(list.count - cap) }
        }
    }

    /// The last `n` exchanges, oldest first.
    public func recent(_ n: Int) -> [Exchange] {
        exchanges.withLock { Array($0.suffix(max(0, n))) }
    }

    public func clear() {
        exchanges.withLock { $0.removeAll() }
    }
}
