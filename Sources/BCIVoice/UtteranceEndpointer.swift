import Foundation

/// Decides when a spoken turn is over.
///
/// The recognizer's own `isFinal` fires on short pauses, so ending the turn
/// there split sentences: the Oct 13 interaction log has turns that end in
/// "…so the", "…like the" and "…once we're". Here `isFinal` only closes a
/// *segment*; the turn ends once `trailingSilence` has passed with no new words
/// (or at the caller's hard timeout, which the listener enforces).
///
/// Pure value type: no audio, no clock. The listener feeds it recognizer
/// results with timestamps and asks `shouldFinish(at:)`.
public struct UtteranceEndpointer: Sendable, Equatable {
    public let trailingSilence: TimeInterval
    /// Segments the recognizer has already finalized, in order.
    public private(set) var closedSegments: [String] = []
    /// The latest text of the segment still being recognized.
    public private(set) var openSegment = ""
    /// When the heard words last changed. nil until the first words arrive.
    public private(set) var lastChange: Date?

    public init(trailingSilence: TimeInterval) {
        self.trailingSilence = trailingSilence
    }

    /// Records a recognizer result for the open segment. `isFinal` closes the
    /// segment (the caller starts a fresh recognition request); it does not end
    /// the turn. Only a change in the words moves `lastChange`, so the pause
    /// that made the recognizer finalize still counts toward the silence.
    public mutating func observe(_ text: String, isFinal: Bool, at time: Date) {
        if text != openSegment {
            openSegment = text
            if !text.isEmpty { lastChange = time }
        }
        if isFinal {
            if !openSegment.isEmpty { closedSegments.append(openSegment) }
            openSegment = ""
        }
    }

    /// Everything heard this turn, segments joined with a space; nil if nothing.
    public var transcript: String? {
        let parts = closedSegments + (openSegment.isEmpty ? [] : [openSegment])
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// True once words have been heard and none have changed for `trailingSilence`.
    public func shouldFinish(at time: Date) -> Bool {
        guard let lastChange, transcript != nil else { return false }
        return time.timeIntervalSince(lastChange) >= trailingSilence
    }
}
