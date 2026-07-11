import BCICore
import Foundation
import Speech

public enum VoiceInputFactory {
    public struct Resolved: Sendable {
        public let recognizer: any DictationRecognizing
        public let kind: VoiceCapabilityKind
        public let warning: String?
    }

    /// `overrideAvailability` is a testability seam (mirrors
    /// `PredictorFactory.live(modelDirectory:)`): pass a fixed value in tests
    /// to force a branch without depending on the test machine's actual
    /// Speech-framework/locale state.
    ///
    /// This only checks capability *existence* — it never requests TCC
    /// authorization. That happens lazily, inside
    /// `PushToTalkSpeechRecognizerService.requestAuthorization()`, the first
    /// time the user actually holds the push-to-talk button. Requesting
    /// permission merely from resolving this factory (i.e. at app launch)
    /// would surprise the user before they've ever touched the feature.
    public static func live(overrideAvailability: Bool? = nil) -> Resolved {
        let available = overrideAvailability ?? (SFSpeechRecognizer(locale: Locale(identifier: "en-US"))?.isAvailable ?? false)
        guard available else {
            BCILog.voice.notice("On-device speech recognition unavailable for this locale/Mac; using stub")
            return Resolved(recognizer: StubDictationRecognizer(), kind: .stub, warning: nil)
        }
        return Resolved(recognizer: PushToTalkSpeechRecognizerService(), kind: .live, warning: nil)
    }
}
