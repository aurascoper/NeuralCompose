import Foundation
import BCICore

/// Voice-driven command recognizer: microphone audio → transcript
/// → `AppCommand?` (with a diagnostic `CommandRecognitionResult`).
///
/// `VoiceCommandRecognizing` is a *sibling* of `AppCommandRecognizing`,
/// not a refinement. The recognizer owns the full
/// microphone-to-command path: the ASR pipeline, the vocabulary,
/// and the parser that turns the final transcript into a
/// command. This keeps the wiring in `AppViewModel` to a single
/// method call (`voiceInput.recognizeLastTranscript()`) and lets
/// the recognizer decide internally how much of the path it
/// implements:
///
///   - The stub never produces a transcript, so its
///     `recognizeLastTranscript()` returns nil and the dispatcher
///     sees nothing.
///   - The real `SpeechCommandRecognizerService` runs the ASR
///     pipeline, then runs a parser over the transcript. The
///     parser can be a deterministic stub, a fuzzy recognizer, or
///     (in the future) an embedding-based one — swapped at the
///     recognizer's construction time without changing the
///     protocol or the dispatcher's interface.
///
/// **Lifecycle is push-to-talk.** The recognizer holds a single
/// `SFSpeechRecognizer` instance and a single `AVAudioEngine`. The
/// mic is open only between an explicit `startCommand()` /
/// `stopCommand()` pair (or `cancelCommand()` for abandon). Never
/// a continuously-running stream, never an ambient listener. Same
/// privacy posture as `DictationRecognizing`.
///
/// **Permissions.** `requestAuthorization()` is separate from
/// `startCommand()` so a caller can show its own explanatory UI
/// before the system permission prompt appears, and so
/// authorization state is independently testable. The OS
/// short-circuits the second request when the first was already
/// granted; this is fine because both the dictation path and the
/// command path share the same TCC permission
/// (`NSSpeechRecognitionUsageDescription` + `NSMicrophoneUsageDescription`).
public protocol VoiceCommandRecognizing: Sendable {

    /// True if this is the SFSpeechRecognizer-backed implementation;
    /// false if it's the stub. Drives the privacy banner's
    /// "live vs. stub" indicator, mirroring `DictationRecognizing`.
    var isLive: Bool { get }

    /// Short identifier for the privacy banner / metrics view.
    /// Names the speech-engine backend (e.g. "sfspeech-cmd-en-US"
    /// for the live impl, "stub-cmd" for the fallback).
    var engineIdentifier: String { get }

    /// Requests speech-recognition + microphone authorization.
    /// Returns `true` only when both are granted. Idempotent.
    func requestAuthorization() async -> Bool

    /// Begins capturing mic audio for command recognition. Throws
    /// `BCIError.speechRecognitionUnavailable` if the underlying
    /// engine can't start (e.g. locale not supported, no
    /// permission). The call is a no-op when already recording.
    func startCommand() async throws

    /// Stops capturing and returns the final transcript for the
    /// whole held-down utterance. Safe to call when not recording
    /// (returns `""`). The returned `String` is the raw ASR
    /// output; `recognizeLastTranscript()` then applies the
    /// parser to produce an `AppCommand?`.
    func stopCommand() async throws -> String

    /// Abandons the in-flight utterance with no final transcript.
    /// Safe to call when not recording.
    func cancelCommand() async

    /// Runs the most recent transcript through the recognizer's
    /// parser and returns the matched command plus a diagnostic
    /// record. The transcript is the one returned by the most
    /// recent `stopCommand()`. Returns `(nil, result)` when the
    /// transcript doesn't match any command.
    func recognizeLastTranscript() async -> (AppCommand?, CommandRecognitionResult)
}
