import Foundation
import BCICore

/// Diagnostic record produced by every command-recognition attempt.
///
/// Today this goes to `BCILog.voice` and (in the future) the debug
/// metrics panel. Tomorrow it becomes the dataset for evaluating
/// fuzzy / embedding-based recognizers — every recognition attempt
/// is a labeled example (transcript -> command, or transcript ->
/// rejection). The shape is intentionally stable so logs from old
/// versions remain readable as the recognizer implementations grow
/// more sophisticated.
///
/// **Always non-nil** when returned from a recognizer's `recognize(...)`
/// call, even when the recognizer matched a command — the record
/// captures the full path (transcript -> normalized -> score ->
/// command-or-rejection) so a future reviewer can see *why* a
/// particular command was chosen.
public struct CommandRecognitionResult: Sendable, Equatable {
    /// The original transcript as received from the upstream
    /// (typed query, ASR output, etc.). Preserved verbatim so
    /// downstream consumers can reproduce the recognition decision.
    public let transcript: String

    /// The transcript after normalization (lowercasing, trim,
    /// politeness stripping, etc.). Empty if the transcript was
    /// empty after normalization.
    public let normalized: String

    /// The command that was matched, or `nil` if rejected.
    public let command: AppCommand?

    /// Confidence score in `[0, 1]`, or `nil` if the recognizer
    /// doesn't produce one. A deterministic exact-match recognizer
    /// returns `1.0` on a hit and `0.0` on a miss. A fuzzy
    /// recognizer returns a graded score. An LLM-based recognizer
    /// would return its self-reported confidence.
    public let confidence: Float?

    /// Why the recognizer rejected the transcript, when it did.
    /// `nil` when a command was matched. The enum is intentionally
    /// closed (not a free-form string) so rejection-reason stats
    /// can be aggregated for recognizer-quality dashboards.
    public let rejectionReason: RejectionReason?

    public enum RejectionReason: String, Sendable, Equatable, Codable {
        /// The transcript was empty after normalization.
        case emptyTranscript
        /// No alias matched with sufficient confidence.
        case noMatch
        /// The top two matches were too close to call (ambiguity
        /// margin violated). Surfaced as a rejection rather than a
        /// guess because command actions are side-effecting.
        case ambiguous
        /// The recognizer implementation rejected the transcript
        /// for some other reason (e.g. embedded in a longer
        /// sentence, mid-phrase qualifier, etc.). The reason
        /// string carries the implementation-specific detail.
        case other
    }

    public init(
        transcript: String,
        normalized: String,
        command: AppCommand?,
        confidence: Float?,
        rejectionReason: RejectionReason?
    ) {
        self.transcript = transcript
        self.normalized = normalized
        self.command = command
        self.confidence = confidence
        self.rejectionReason = rejectionReason
    }
}
