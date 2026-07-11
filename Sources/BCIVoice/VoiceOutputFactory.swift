import BCICore
import Foundation

public enum VoiceOutputFactory {
    public struct Resolved: Sendable {
        public let synthesizer: any SpeechSynthesizing
        public let kind: VoiceCapabilityKind
        public let warning: String?
    }

    public static func live() -> Resolved {
        Resolved(synthesizer: AVSpeechSynthesizerService(), kind: .live, warning: nil)
    }
}
