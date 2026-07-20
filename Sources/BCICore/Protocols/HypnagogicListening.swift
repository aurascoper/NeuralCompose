import Foundation

/// Turn-based, on-device speech capture for the hypnagogic loop. Unlike a
/// push-to-talk recognizer, `listen(timeout:)` opens the mic, waits for one
/// utterance (or silence), returns the recognized text, and closes the mic —
/// so the mic is only ever hot during an explicit listen turn (never during
/// TTS playback), and there is no continuous background recording.
///
/// Conformers MUST transcribe on-device — raw audio never leaves the machine;
/// only the resulting text is returned to the caller. Kept as a `Sendable`
/// seam so the hypnagogic loop is testable with a scripted spy rather than a
/// real microphone.
public protocol HypnagogicListening: Sendable {
    var isLive: Bool { get }

    /// Requests microphone + speech-recognition authorization. Returns whether
    /// both were granted.
    func requestAuthorization() async -> Bool

    /// Opens the mic and returns the recognized utterance, or `nil` if only
    /// silence was heard before `timeout` elapses. The mic is always closed
    /// before returning, whether or not an utterance was heard.
    func listen(timeout: TimeInterval) async throws -> String?

    /// Aborts an in-flight `listen` (resuming it with `nil`) and closes the mic.
    /// Safe to call when idle.
    func cancel() async
}
