import Foundation

/// Speaks composed text aloud on explicit user action. Never invoked
/// ambiently — callers own deciding when speech should happen.
public protocol SpeechSynthesizing: Sendable {
    var isLive: Bool { get }
    var voiceIdentifier: String { get }

    /// Suspends until the utterance finishes, or throws `BCIError.cancelled`
    /// if interrupted by `stopSpeaking()`.
    func speak(_ text: String) async throws

    /// Speaks with prosody (rate / pitch / volume) shaping. Conformers that
    /// support prosody override this; the default implementation ignores the
    /// shaping and falls back to plain `speak(_:)`, so existing conformers
    /// (e.g. the stub) need no change.
    func speak(_ text: String, prosody: SpeechProsody) async throws

    /// Interrupts whatever is currently being spoken. Safe to call when idle.
    func stopSpeaking() async
}

public extension SpeechSynthesizing {
    func speak(_ text: String, prosody: SpeechProsody) async throws {
        try await speak(text)
    }
}

/// Prosody shaping for a spoken utterance. Every field is optional; `nil` means
/// "use the synthesizer's default." Values map directly onto `AVSpeechUtterance`
/// (`rate` 0…1, `pitchMultiplier` 0.5…2.0, `volume` 0…1, `preUtteranceDelay`
/// seconds) but this type lives in BCICore so the `SpeechSynthesizing` seam
/// stays AVFoundation-free and fully testable with spies.
public struct SpeechProsody: Sendable, Equatable {
    public var rate: Float?
    public var pitchMultiplier: Float?
    public var volume: Float?
    public var preUtteranceDelay: TimeInterval?

    public init(
        rate: Float? = nil,
        pitchMultiplier: Float? = nil,
        volume: Float? = nil,
        preUtteranceDelay: TimeInterval? = nil
    ) {
        self.rate = rate
        self.pitchMultiplier = pitchMultiplier
        self.volume = volume
        self.preUtteranceDelay = preUtteranceDelay
    }

    /// Slow, low-pitched, soft — for hypnagogic cue playback that must not spike
    /// arousal. Deliberately conservative; the safety rationale (avoid harsh
    /// treble / sudden onset waking the user) lives in `SLEEP_CYCLE_DESIGN.md`.
    public static let hypnagogic = SpeechProsody(
        rate: 0.35,
        pitchMultiplier: 0.8,
        volume: 0.6,
        preUtteranceDelay: 0.4
    )
}
