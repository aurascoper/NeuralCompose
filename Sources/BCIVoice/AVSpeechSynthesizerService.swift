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
            ?? AVSpeechSynthesisVoice(language: AVSpeechSynthesisVoice.currentLanguageCode())?.identifier
            ?? "system-default"
        synthesizer.delegate = delegateProxy
    }

    public func speak(_ text: String) async throws {
        await stopSpeaking()
        let utterance = AVSpeechUtterance(string: text)
        if let voice = AVSpeechSynthesisVoice(identifier: voiceIdentifier) {
            utterance.voice = voice
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            pendingContinuation = continuation
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
    var onFinish: (() -> Void)?
    var onCancel: (() -> Void)?

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        onFinish?()
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        onCancel?()
    }
}
