import BCICore
import Foundation
import Speech

/// Resolves the right `VoiceCommandRecognizing` implementation:
/// `SpeechCommandRecognizerService` (real `SFSpeechRecognizer` +
/// `AVAudioEngine`) when the system has on-device speech recognition
/// available, `StubVoiceCommandRecognizer` (zero-dependency
/// fallback) otherwise.
///
/// **Mirrors `VoiceInputFactory`'s shape and contract.** Same
/// `overrideAvailability: Bool?` testability seam. Same
/// availability check (constructs an `SFSpeechRecognizer` for the
/// default locale and reads `isAvailable`). Same "never prompts for
/// permission at launch" privacy invariant — the factory only
/// checks capability, never calls `requestAuthorization()`. TCC
/// authorization happens lazily inside the recognizer itself, the
/// first time the user actually holds the push-to-command button.
public enum VoiceCommandFactory {

    public struct Resolved: Sendable {
        public let recognizer: any VoiceCommandRecognizing
        public let kind: VoiceCapabilityKind
        public let warning: String?
    }

    /// `overrideAvailability` is a testability seam (mirrors
    /// `VoiceInputFactory.live(overrideAvailability:)`): pass a
    /// fixed value in tests to force a branch without depending on
    /// the test machine's actual Speech-framework/locale state.
    public static func live(
        overrideAvailability: Bool? = nil,
        parser: @escaping @Sendable (String, [CommandDescriptor]) -> AppCommand? = { _, _ in nil },
        vocabulary: [CommandDescriptor] = []
    ) -> Resolved {
        let available = overrideAvailability ?? (SFSpeechRecognizer(locale: Locale(identifier: "en-US"))?.isAvailable ?? false)
        guard available else {
            BCILog.voice.notice("On-device speech recognition unavailable for this locale/Mac; using stub for voice commands")
            return Resolved(recognizer: StubVoiceCommandRecognizer(), kind: .stub, warning: nil)
        }
        return Resolved(
            recognizer: SpeechCommandRecognizerService(
                locale: Locale(identifier: "en-US"),
                parser: parser,
                vocabulary: vocabulary
            ),
            kind: .live,
            warning: nil
        )
    }
}
