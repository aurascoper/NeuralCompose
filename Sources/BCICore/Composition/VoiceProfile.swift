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
    /// Terms the hypnagogic listener should expect (names, jargon) — passed to
    /// the recognizer as `contextualStrings`. Hand-edited; nil ⇒ none.
    public var recognitionVocabulary: [String]?
    /// Seconds without a new word before a spoken turn ends. nil ⇒
    /// `HypnagogicListener.defaultTrailingSilence`.
    public var endOfUtteranceSilence: Double?

    public init(usePersonalVoice: Bool? = nil, voiceIdentifier: String? = nil,
                prosody: SpeechProsody? = nil, register: String? = nil,
                recognitionVocabulary: [String]? = nil, endOfUtteranceSilence: Double? = nil) {
        self.usePersonalVoice = usePersonalVoice
        self.voiceIdentifier = voiceIdentifier
        self.prosody = prosody
        self.register = register
        self.recognitionVocabulary = recognitionVocabulary
        self.endOfUtteranceSilence = endOfUtteranceSilence
    }

    /// The canonical on-disk location, mirroring the app's other config/telemetry
    /// files under `~/Documents/NeuralCompose/`.
    public static func defaultURL() -> URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?
            .appendingPathComponent("NeuralCompose", isDirectory: true)
            .appendingPathComponent("voice-profile.json")
    }

    /// Baseline domain vocabulary supplied to SFSpeechRecognizer even on cold
    /// launches where ~/Documents/NeuralCompose/voice-profile.json is absent.
    public static let defaultRecognitionVocabulary: [String] = [
        "NeuralCompose",
        "Hunter",
        "aurascoper",
        "GitHub",
        "Antigravity",
        "Ollama",
        "Claude",
        "Opus",
        "Sonnet",
        "Witness",
        "hypnagogic",
        "dialectic",
        "Reflective",
        "Contemplative",
        "Focused",
        "Semantica",
        "Multica",
        "JEPA",
        "MPPI",
        "MLX",
        "EEG",
        "Muse",
        "Oklo",
        "samarium",
        "automorphism",
        "Cantor space",
        "eigen-behaviors",
        "Gene Ontology",
        "symbolic dynamics",
        "Yang-Mills",
        "Exponential Time Hypothesis",
        "disproof",
        "equifinality",
        "von Bertalanffy",
        "genomes",
        "renormalization group",
        "Brett",
        "Qwen",
        "Uncle Tom",
        "Fast Wireframe",
        "wireframe",
        "Slow Core",
        "Hollow Shell",
        "Plasticity Shell",
        "Gold Laya Flux",
        "Laya",
        "SIGReg",
        "ST-JEMA",
        "Tarjan",
        "Betti",
        "edge cycle",
        "vertex cycle",
        "Mahalanobis",
        "carbonic acid",
        "potassium hydroxide",
        "citric acid"
    ]

    /// Merges any profile-specific vocabulary with `defaultRecognitionVocabulary`
    /// while preserving order and deduplicating case-insensitively.
    public static func effectiveRecognitionVocabulary(for profile: VoiceProfile?) -> [String] {
        var result: [String] = []
        var seen = Set<String>()
        for term in (profile?.recognitionVocabulary ?? []) + defaultRecognitionVocabulary {
            let key = term.lowercased()
            if seen.insert(key).inserted {
                result.append(term)
            }
        }
        return result
    }

    /// Load the profile, or nil if the file is absent / unreadable / malformed.
    /// Never throws — a bad profile must not block launch.
    public static func loadDefault() -> VoiceProfile? {
        // Absent file → nil silently (the intended, launch-safe fallback to env/auto).
        guard let url = defaultURL(), let data = try? Data(contentsOf: url) else { return nil }
        do {
            return try JSONDecoder().decode(VoiceProfile.self, from: data)
        } catch {
            // Present but undecodable (e.g. a hand-edit typo) — still don't block
            // launch, but leave a breadcrumb so a silently-ignored profile isn't a
            // mystery, matching the app's "log why we fell back" discipline elsewhere.
            BCILog.voice.notice("voice-profile.json present but undecodable; using env/auto defaults: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}
