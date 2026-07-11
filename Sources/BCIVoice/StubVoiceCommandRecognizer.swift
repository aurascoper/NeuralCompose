import BCICore
import Foundation

/// Zero-dependency fallback for the voice command recognizer. Touches
/// no AVAudioEngine/Speech API at all, so resolving and constructing
/// this never requires any system permission or hardware, and never
/// opens the microphone. Resolving and instantiating this is a
/// constant-time no-op.
///
/// The stub holds no state and never produces a meaningful
/// transcript. `recognizeLastTranscript()` always returns
/// `(nil, result)` with `result.rejectionReason == .emptyTranscript`,
/// which surfaces to the UI as a `commandWarning` — the user knows
/// the recognizer can't hear anything and can swap to a live
/// recognizer when the system has the capability.
public final class StubVoiceCommandRecognizer: VoiceCommandRecognizing, @unchecked Sendable {
    public let isLive = false
    public let engineIdentifier = "stub-cmd"

    public init() {}

    public func requestAuthorization() async -> Bool { false }

    public func startCommand() async throws {
        throw BCIError.speechRecognitionUnavailable(reason: "on-device speech recognition not available")
    }

    public func stopCommand() async throws -> String { "" }

    public func cancelCommand() async {}

    public func recognizeLastTranscript() async -> (AppCommand?, CommandRecognitionResult) {
        (nil, CommandRecognitionResult(
            transcript: "",
            normalized: "",
            command: nil,
            confidence: 0.0,
            rejectionReason: .emptyTranscript
        ))
    }
}
