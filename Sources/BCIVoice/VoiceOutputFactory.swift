import BCICore
import Foundation

public enum VoiceOutputFactory {
    public struct Resolved: Sendable {
        public let synthesizer: any SpeechSynthesizing
        public let kind: VoiceCapabilityKind
        public let warning: String?
    }

    /// Resolve the live synthesizer. `voiceIdentifier`, when non-nil, pins a
    /// specific voice (e.g. a Personal Voice id from `NEURALCOMPOSE_VOICE_ID`);
    /// otherwise `AVSpeechSynthesizerService` auto-selects the best available
    /// voice — the user's on-device **Personal Voice** first (if authorized), then
    /// an installed Enhanced/Premium neural voice. If none of those is present the
    /// voice still works but sounds robotic — surface a one-time hint. Never gates
    /// to stub: AVSpeech is always available on-device.
    public static func live(voiceIdentifier: String? = nil) -> Resolved {
        let hasGoodVoice = voiceIdentifier != nil
            || AVSpeechSynthesizerService.bestPersonalVoiceIdentifier() != nil
            || AVSpeechSynthesizerService.bestNeuralVoiceIdentifier() != nil
        let warning = hasGoodVoice
            ? nil
            : "For a natural voice, record a Personal Voice (System Settings → Accessibility → Personal Voice) or install an Enhanced/Premium voice (Spoken Content → Manage Voices)."
        return Resolved(synthesizer: AVSpeechSynthesizerService(voiceIdentifier: voiceIdentifier), kind: .live, warning: warning)
    }
}
