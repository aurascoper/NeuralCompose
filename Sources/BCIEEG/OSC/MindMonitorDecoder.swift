import Foundation
import BCICore

/// Maps decoded OSC messages to `EEGSample`s using Mind Monitor's specific
/// address conventions. Kept separate from `MuseOSCDecoder` (generic OSC
/// message decoding, no Mind Monitor knowledge) and from
/// `MindMonitorOSCStream` (networking, no decoding knowledge) so this
/// mapping is testable with plain `OSCMessage` values — no socket needed.
///
/// Mind Monitor sends several `/muse/*` addresses (`/muse/acc`,
/// `/muse/gyro`, `/muse/elements`, `/muse/batt`, ...). Only `/muse/eeg` is
/// handled today; everything else returns `nil` and is silently ignored by
/// the stream — not an error, just a message this decoder doesn't need yet.
public enum MindMonitorDecoder {
    public static let eegAddress = "/muse/eeg"

    /// Returns an `EEGSample` if `message` is a `/muse/eeg` message with at
    /// least 4 float arguments, timestamped at `timestamp`. Only the first
    /// 4 floats are used — TP9, AF7, AF8, TP10, in that order, matching
    /// this project's fixed 4-channel montage (see
    /// `MindMonitorOSCStream.channelCount`).
    ///
    /// Real Mind Monitor traffic sends **6** floats per `/muse/eeg`
    /// message, not 4 — found via a live capture against a real device
    /// (see `MindMonitorDecoderTests`'s fixture, byte-for-byte from that
    /// capture). The trailing 2 values are dropped; this project doesn't
    /// have a use for them yet and doesn't know their semantics with
    /// certainty (auxiliary/reference channel candidates, unconfirmed).
    /// Accepting "4 or more" rather than hard-coding "exactly 6" is
    /// deliberate — it tolerates a Mind Monitor version that sends 4 or 5
    /// instead, rather than needing another live capture to relax this
    /// again.
    ///
    /// `timestamp` comes from the stream's own arrival-time clock (seconds
    /// since the stream started), not from anything in the OSC packet —
    /// Mind Monitor's `/muse/eeg` payload carries no per-sample hardware
    /// timestamp of its own.
    ///
    /// Returns `nil` for any other address, or for a `/muse/eeg` message
    /// with fewer than 4 float arguments. The caller (`MindMonitorOSCStream`)
    /// logs and counts this as a dropped packet rather than treating it as
    /// fatal — one malformed or unexpected packet shouldn't end the session
    /// on an inherently lossy UDP transport.
    public static func sample(from message: OSCMessage, timestamp: TimeInterval) -> EEGSample? {
        guard message.address == eegAddress else { return nil }
        let floats = message.floatArguments
        guard floats.count >= 4 else { return nil }
        return EEGSample(timestamp: timestamp, channels: Array(floats.prefix(4)))
    }
}
