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

    /// The coherence pole's voice in the dialectic loop — identical to
    /// `hypnagogic` (calm, flat, slow).
    public static let hypnagogicStabilizer = hypnagogic

    /// The displacement pole's voice — a touch quicker and brighter so the
    /// dreaming undercurrent is *audibly* different, while staying inside the
    /// same arousal-safe envelope (still slow and soft, never harsh or sudden).
    public static let hypnagogicDreamer = SpeechProsody(
        rate: 0.42,
        pitchMultiplier: 0.98,
        volume: 0.6,
        preUtteranceDelay: 0.3
    )

    /// The coherence pole's voice in a **waking** dialectic — present and
    /// natural-paced (near the AVSpeechUtterance default rate), NOT the slow
    /// arousal-safe hypnagogic envelope. Used by the waking role set for the
    /// Focused / Reflective / Contemplative profiles.
    public static let wakingCoherent = SpeechProsody(
        rate: 0.5,
        pitchMultiplier: 1.0,
        volume: 0.9,
        preUtteranceDelay: 0.1
    )

    /// The displacement pole's **waking** voice — a touch quicker and brighter
    /// so the opposing voice is audibly distinct, without the sleepy slowness.
    public static let wakingDivergent = SpeechProsody(
        rate: 0.54,
        pitchMultiplier: 1.06,
        volume: 0.9,
        preUtteranceDelay: 0.05
    )

    /// Weighted mean of several prosodies — the mechanism that makes tension
    /// *audible*: a spoken turn is voiced by blending the role voices in
    /// proportion to the competition's probabilities, so a close call carries
    /// the losing pole's colour even though only the winner's words are said.
    /// Each field is averaged only over the contributors that specify it (a
    /// `nil` field abstains); non-positive weights are ignored. Returns an
    /// all-`nil` prosody when nothing contributes.
    public static func blend(_ weighted: [(prosody: SpeechProsody, weight: Float)]) -> SpeechProsody {
        func mean<T: BinaryFloatingPoint>(_ get: (SpeechProsody) -> T?) -> T? {
            var acc: T = 0, wsum: T = 0
            for (p, w) in weighted where w > 0 {
                if let v = get(p) { let wt = T(w); acc += v * wt; wsum += wt }
            }
            return wsum > 0 ? acc / wsum : nil
        }
        return SpeechProsody(
            rate: mean { $0.rate },
            pitchMultiplier: mean { $0.pitchMultiplier },
            volume: mean { $0.volume },
            preUtteranceDelay: mean { $0.preUtteranceDelay }
        )
    }
}
