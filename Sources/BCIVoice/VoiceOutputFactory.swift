import BCICore
import Foundation

public enum VoiceOutputFactory {
    public struct Resolved: Sendable {
        public let synthesizer: any SpeechSynthesizing
        public let kind: VoiceCapabilityKind
        public let warning: String?
    }

    public static func live() -> Resolved {
        // AVSpeechSynthesizerService auto-selects the best installed Enhanced/
        // Premium (neural) voice; if only the compact default is installed, the
        // voice still works but sounds robotic — surface a one-time hint. Never
        // gates to stub: AVSpeech is always available on-device.
        let warning = AVSpeechSynthesizerService.bestNeuralVoiceIdentifier() == nil
            ? "For a natural voice, install an Enhanced or Premium voice: System Settings → Accessibility → Spoken Content → System Voice → Manage Voices."
            : nil
        return Resolved(synthesizer: AVSpeechSynthesizerService(), kind: .live, warning: warning)
    }
}
