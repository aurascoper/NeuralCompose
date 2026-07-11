import Foundation

/// Push-to-talk speech-to-text: mic is only ever open between a
/// `startRecording()`/`stopRecording()` pair, both explicitly triggered by
/// the user holding a control. Never a continuously-running stream.
///
/// Ships with no partial-transcription hypotheses in this phase — only a
/// single final transcript per held-down utterance. Live partial results
/// (for in-progress UI feedback) are a deliberately postponed follow-up:
/// they introduce cancellation/revision semantics not needed for the core
/// requirement of "one utterance in, one string out." When added, expose
/// them as `func partialTranscripts() -> any AsyncSequence<String>` rather
/// than a concrete stream type, so the transport isn't baked into this
/// protocol.
public protocol DictationRecognizing: TextInputSource {
    var isLive: Bool { get }
    var engineIdentifier: String { get }

    /// Requests mic + speech-recognition authorization. Separate from
    /// `startRecording()` so a caller can show its own explanatory UI before
    /// the system permission prompt appears, and so authorization state is
    /// independently testable. Idempotent — safe to call again once granted.
    func requestAuthorization() async -> Bool

    /// Begins capturing mic audio. Callers must have already received
    /// `true` from `requestAuthorization()`.
    func startRecording() async throws

    /// Stops capturing and returns the final transcript for the whole
    /// held-down utterance. Call on trigger release.
    func stopRecording() async throws -> String

    /// Abandons the in-flight utterance with no final transcript. Safe to
    /// call even when not recording.
    func cancelRecording() async
}
