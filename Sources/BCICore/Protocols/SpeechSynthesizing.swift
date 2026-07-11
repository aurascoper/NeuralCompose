import Foundation

/// Speaks composed text aloud on explicit user action. Never invoked
/// ambiently — callers own deciding when speech should happen.
public protocol SpeechSynthesizing: Sendable {
    var isLive: Bool { get }
    var voiceIdentifier: String { get }

    /// Suspends until the utterance finishes, or throws `BCIError.cancelled`
    /// if interrupted by `stopSpeaking()`.
    func speak(_ text: String) async throws

    /// Interrupts whatever is currently being spoken. Safe to call when idle.
    func stopSpeaking() async
}
