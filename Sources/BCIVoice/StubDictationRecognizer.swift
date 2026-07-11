import BCICore
import Foundation

/// Zero-dependency fallback — touches no AVAudioEngine/Speech API at all, so
/// resolving and constructing this never requires any system permission or
/// hardware, and never opens the microphone.
public final class StubDictationRecognizer: DictationRecognizing, @unchecked Sendable {
    public let isLive = false
    public let engineIdentifier = "stub-dictation"
    public var identifier: String { engineIdentifier }

    public init() {}

    public func requestAuthorization() async -> Bool { false }

    public func startRecording() async throws {
        throw BCIError.speechRecognitionUnavailable(reason: "on-device speech recognition not available")
    }

    public func stopRecording() async throws -> String { "" }

    public func cancelRecording() async {}
}
