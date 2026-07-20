import AVFoundation
import BCICore
import Foundation

/// TTS via `AVSpeechSynthesizer`. Speaks fully on-device — no network
/// involvement, consistent with the rest of NeuralCompose's privacy story.
public actor AVSpeechSynthesizerService: SpeechSynthesizing {
    public nonisolated let isLive = true
    public nonisolated let voiceIdentifier: String

    private let synthesizer = AVSpeechSynthesizer()
    private let delegateProxy = SpeechSynthesizerDelegateProxy()
    private var pendingContinuation: CheckedContinuation<Void, any Error>?

    public init(voiceIdentifier: String? = nil) {
        self.voiceIdentifier = voiceIdentifier
            ?? Self.bestPersonalVoiceIdentifier()                                     // the user's own on-device voice (if authorized)
            ?? Self.bestNeuralVoiceIdentifier()                                       // else best installed Premium/Enhanced
            ?? AVSpeechSynthesisVoice(language: AVSpeechSynthesisVoice.currentLanguageCode())?.identifier
            ?? "system-default"
        synthesizer.delegate = delegateProxy
    }

    /// Identifier of the best installed NEURAL (Enhanced/Premium) voice for
    /// `language` (default: current locale), preferring Premium over Enhanced.
    /// Returns nil when only the compact/default voice is installed — the robotic
    /// case. macOS 14+'s downloadable Enhanced/Premium voices are neural and sound
    /// dramatically better than the compact default, at no extra bundle cost and
    /// still fully on-device (installed via System Settings, never fetched by the
    /// app). Pure enumeration, no synthesis, no network.
    public nonisolated static func bestNeuralVoiceIdentifier(language: String? = nil) -> String? {
        let prefix = (language ?? AVSpeechSynthesisVoice.currentLanguageCode()).prefix(2).lowercased()
        return AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.lowercased().hasPrefix(prefix)
                      && $0.quality.rawValue > AVSpeechSynthesisVoiceQuality.default.rawValue }
            .max { $0.quality.rawValue < $1.quality.rawValue }?   // highest quality wins (premium > enhanced)
            .identifier
    }

    /// Identifier of an installed **Personal Voice** — the user's own voice,
    /// recorded and compiled entirely on-device (System Settings → Accessibility →
    /// Personal Voice). Personal voices report `.default` quality, so they are
    /// invisible to `bestNeuralVoiceIdentifier`; this is a separate selector keyed
    /// on the `.isPersonalVoice` trait. Returns nil until the app has been granted
    /// personal-voice authorization (`requestPersonalVoiceAuthorization`) — before
    /// that, personal voices do not appear in `speechVoices()`. Prefers a voice for
    /// `language` (default: current locale), else any personal voice.
    public nonisolated static func bestPersonalVoiceIdentifier(language: String? = nil) -> String? {
        let prefix = (language ?? AVSpeechSynthesisVoice.currentLanguageCode()).prefix(2).lowercased()
        let personal = AVSpeechSynthesisVoice.speechVoices().filter { $0.voiceTraits.contains(.isPersonalVoice) }
        return (personal.first { $0.language.lowercased().hasPrefix(prefix) } ?? personal.first)?.identifier
    }

    /// Request authorization to use the user's Personal Voice (macOS 14+). Mirrors
    /// the repo's `requestAuthorization()` convention — gate on `.authorized`,
    /// return `Bool` — but the API is already async, so no continuation bridge.
    /// Requires the user to have enabled System Settings → Accessibility → Personal
    /// Voice → "Allow Apps to Request to Use". Fully on-device; presents a one-time
    /// consent prompt (per app code identity). Do not await on a launch path that
    /// must not block — an unanswered prompt does not return until the user responds.
    public nonisolated static func requestPersonalVoiceAuthorization() async -> Bool {
        await AVSpeechSynthesizer.requestPersonalVoiceAuthorization() == .authorized
    }

    public func speak(_ text: String) async throws {
        try await speak(text, prosody: SpeechProsody())
    }

    public func speak(_ text: String, prosody: SpeechProsody) async throws {
        try await speak(text, prosody: prosody, onWord: nil)
    }

    public func speak(_ text: String, prosody: SpeechProsody,
                      onWord: (@Sendable (SpokenWord) -> Void)?) async throws {
        await stopSpeaking()
        let utterance = AVSpeechUtterance(string: text)
        if let voice = AVSpeechSynthesisVoice(identifier: voiceIdentifier) {
            utterance.voice = voice
        }
        // Apply only the fields the caller set; leave the rest at AVSpeech
        // defaults. Clamp to AVSpeechUtterance's documented ranges.
        if let rate = prosody.rate {
            utterance.rate = min(AVSpeechUtteranceMaximumSpeechRate,
                                 max(AVSpeechUtteranceMinimumSpeechRate, rate))
        }
        if let pitch = prosody.pitchMultiplier {
            utterance.pitchMultiplier = min(2.0, max(0.5, pitch))
        }
        if let volume = prosody.volume {
            utterance.volume = min(1.0, max(0.0, volume))
        }
        if let delay = prosody.preUtteranceDelay {
            utterance.preUtteranceDelay = max(0, delay)
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            pendingContinuation = continuation
            delegateProxy.onWord = onWord
            delegateProxy.onFinish = { [weak self] in Task { await self?.resume(throwing: nil) } }
            delegateProxy.onCancel = { [weak self] in Task { await self?.resume(throwing: BCIError.cancelled) } }
            synthesizer.speak(utterance)
        }
    }

    public func stopSpeaking() async {
        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }
    }

    private func resume(throwing error: (any Error)?) {
        guard let pendingContinuation else { return }
        self.pendingContinuation = nil
        if let error {
            pendingContinuation.resume(throwing: error)
        } else {
            pendingContinuation.resume()
        }
    }
}

/// `AVSpeechSynthesizerDelegate` is an Objective-C protocol requiring an
/// `NSObject` conformer — an `actor` can't inherit from `NSObject`, so this
/// small proxy bridges delegate callbacks back into the actor via plain
/// closures.
private final class SpeechSynthesizerDelegateProxy: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
    // @Sendable: these are assigned self-capturing `Task { await … }` closures from
    // the actor. Newer Swift 6 toolchains treat the setters as `sending` and reject a
    // non-Sendable closure (CI fails to build even though older toolchains accept it).
    var onFinish: (@Sendable () -> Void)?
    var onCancel: (@Sendable () -> Void)?
    var onWord: (@Sendable (SpokenWord) -> Void)?

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                           willSpeakRangeOfSpeechString characterRange: NSRange,
                           utterance: AVSpeechUtterance) {
        guard let onWord else { return }
        let full = utterance.speechString as NSString
        guard characterRange.location != NSNotFound,
              characterRange.location >= 0,
              characterRange.location + characterRange.length <= full.length else { return }
        onWord(SpokenWord(text: full.substring(with: characterRange),
                          characterOffset: characterRange.location))
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        onFinish?()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        onCancel?()
    }
}
