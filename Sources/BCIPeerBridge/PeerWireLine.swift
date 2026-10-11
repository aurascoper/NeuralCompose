import Foundation

/// One line of the fixed two-machine dialectic wire format, agreed with the
/// GPD-side Rust session before either side wrote code (see
/// `decision_registry.md` entry 9): one UTF-8 JSON object per line,
/// newline-delimited, over a plain TCP socket on the tailnet. No wall-clock
/// sync — turns pair by `seq`, never by timestamp.
public struct PeerWireLine: Codable, Sendable, Equatable {
    public let version: Int
    public let session: String
    /// Per-sender turn counter — independent on each side, not a shared
    /// global sequence.
    public let seq: Int
    /// `"gpd"` or `"mac"`.
    public let from: String
    public let text: String
    /// The SENDER's own monotonic clock, in milliseconds. Not comparable
    /// across machines (no wall-clock sync) — diagnostic only.
    public let monoMs: UInt64
    /// The peer `seq` this line answers, or `nil` for the dialer's opening
    /// seed utterance.
    public let inReplyTo: Int?

    private enum CodingKeys: String, CodingKey {
        case version = "v"
        case session, seq, from, text
        case monoMs = "mono_ms"
        case inReplyTo = "in_reply_to"
    }

    public init(
        version: Int = 1,
        session: String,
        seq: Int,
        from: String,
        text: String,
        monoMs: UInt64,
        inReplyTo: Int?
    ) {
        self.version = version
        self.session = session
        self.seq = seq
        self.from = from
        self.text = text
        self.monoMs = monoMs
        self.inReplyTo = inReplyTo
    }
}
