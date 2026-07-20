import Foundation

/// The **slow, semantic clock**: the competition weights as a vector field over
/// the dialogue's history, evolving with *inertia* rather than being recomputed
/// from scratch each turn. Each turn the weights ease a fraction (`inertia`)
/// toward a `target` derived from the fast gloss and the slow interaction
/// history — so the conversation has a direction of travel, and a single noisy
/// EEG window can only budge it slightly.
///
/// This is the "wind, not steering wheel" layer: the gloss and history *bias*
/// which semantic axis leads, they never select an utterance. The `target`
/// policy below is the one knob calibrated by taste (see the plan's
/// code-contribution note) — a deliberately conservative default that is easy
/// to retune without touching the mechanism.
public struct DialecticalField: Sendable, Equatable {

    /// Current weights (seeded to `base`, so the first turn is unbiased).
    public private(set) var weights: DialecticalWeights
    /// The neutral weights the field is pulled back toward.
    public let base: DialecticalWeights
    /// Slow-clock inertia: fraction of the gap to `target` closed per turn.
    public let inertia: Float
    /// Maximum weight shift the bias can induce.
    public let wind: Float

    public init(base: DialecticalWeights, inertia: Float, wind: Float) {
        self.base = base
        self.weights = base
        self.inertia = max(0, min(1, inertia))
        self.wind = wind
    }

    /// Eases the weights one turn toward the biased target. The gloss (fast) and
    /// entropy/drift (slow) are mixed **only here**, so the two clocks stay
    /// separate everywhere upstream.
    @discardableResult
    public mutating func advance(glossScalar: Float, entropy: Float, drift: Float) -> DialecticalWeights {
        let target = Self.target(base: base, glossScalar: glossScalar,
                                 entropy: entropy, drift: drift, wind: wind)
        weights = DialecticalWeights(
            coherence: lerp(weights.coherence, target.coherence),
            resonance: lerp(weights.resonance, target.resonance),
            novelty: lerp(weights.novelty, target.novelty)
        )
        return weights
    }

    private func lerp(_ a: Float, _ b: Float) -> Float { a + (b - a) * inertia }

    // MARK: - Target policy  (← the tunable contribution)

    /// Where the weights *want* to be given the current bias. Conservative
    /// defaults; every shift is scaled by `wind` and the result is clamped
    /// non-negative. This is the function to hand-tune:
    ///  - relaxed (glossScalar → 1) gently favours **novelty**;
    ///  - engaged (glossScalar → 0) gently favours **coherence/resonance**;
    ///  - a wandering dialogue (high **entropy**) reins novelty back in;
    ///  - fast **drift** damps novelty further.
    /// All inputs are in `[0, 1]`; `glossScalar` is already EMA-smoothed.
    public static func target(base: DialecticalWeights, glossScalar: Float,
                              entropy: Float, drift: Float, wind: Float) -> DialecticalWeights {
        let lean = (glossScalar - 0.5) * 2          // [-1, 1]: + relaxed, − engaged
        var novelty = base.novelty + wind * lean
        let coherence = base.coherence - 0.5 * wind * lean
        let resonance = base.resonance - 0.5 * wind * lean
        // EEG-independent history terms: keep the dialogue coherent when it wanders.
        novelty -= 0.5 * wind * entropy
        novelty -= 0.5 * wind * drift
        return DialecticalWeights(
            coherence: max(0, coherence),
            resonance: max(0, resonance),
            novelty: max(0, novelty)
        )
    }
}
