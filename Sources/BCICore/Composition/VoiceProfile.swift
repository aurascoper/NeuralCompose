import Foundation

/// Persisted voice preferences, read once at launch from
/// `~/Documents/NeuralCompose/voice-profile.json` (written by
/// `Scripts/voice-profile.py`). Every field is optional, so an absent file or a
/// missing key falls back to the env vars / auto-selection — the profile only
/// *overrides* what it specifies. This lets the chosen Personal Voice, a default
/// prosody, and an authorial register persist across launches without env flags.
public struct VoiceProfile: Codable, Sendable, Equatable {
    /// Opt in to the user's on-device Personal Voice (mirrors NEURALCOMPOSE_PERSONAL_VOICE=1).
    public var usePersonalVoice: Bool?
    /// Pin a specific voice identifier (mirrors NEURALCOMPOSE_VOICE_ID).
    public var voiceIdentifier: String?
    /// Base prosody the confidence-wobble varies around (defaults to `.wakingCoherent`).
    public var prosody: SpeechProsody?
    /// Authorial register name (e.g. "schopenhauer"). Applied to LLM generation on
    /// the MLX / cloud paths; a no-op on the default stub predictor.
    public var register: String?

    public init(usePersonalVoice: Bool? = nil, voiceIdentifier: String? = nil,
                prosody: SpeechProsody? = nil, register: String? = nil) {
        self.usePersonalVoice = usePersonalVoice
        self.voiceIdentifier = voiceIdentifier
        self.prosody = prosody
        self.register = register
    }

    /// The canonical on-disk location, mirroring the app's other config/telemetry
    /// files under `~/Documents/NeuralCompose/`.
    public static func defaultURL() -> URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("NeuralCompose", isDirectory: true)
            .appendingPathComponent("voice-profile.json")
    }

    /// Load the profile, or nil if the file is absent / unreadable / malformed.
    /// Never throws — a bad profile must not block launch.
    public static func loadDefault() -> VoiceProfile? {
        guard let url = defaultURL(), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(VoiceProfile.self, from: data)
    }
}
