import Foundation

/// The **fast, biological clock**: an EMA-smoothed scalar read off the
/// `SpectralState` gloss. This is a *bias signal*, not a cognitive read —
/// `Muse EEG → band ratios → SpectralState → glossScalar → weight bias`, never
/// `→ mental state → dialogue` (see `SpectralState.honestyCaveat`). It only
/// nudges the weight field; it never selects a response.
///
/// It runs on a *fast* time constant so it tracks the EEG window-to-window,
/// while the `DialecticalField` it feeds moves *slowly* — the two clocks are
/// deliberately separate so a one-window fluctuation cannot rewrite the
/// dialogue's semantic identity (it is absorbed by the field's inertia).
public struct SpectralGloss: Sendable, Equatable {

    /// Smoothed relaxation scalar in `[0, 1]`: 1 ≈ drowsy/relaxed (favour
    /// novelty), 0 ≈ engaged/high-load (favour coherence), 0.5 ≈ neutral.
    public private(set) var value: Float

    public init(value: Float = 0.5) { self.value = value }

    /// Instantaneous mapping of a `SpectralState` to the relaxation scalar. An
    /// absent estimate (stub, missing weights, contaminated window) reads as
    /// neutral rather than biasing either way.
    public static func scalar(for state: SpectralState?) -> Float {
        switch state {
        case .drowsyFatigued:     return 1.0
        case .relaxedWakefulness: return 0.8
        case .neutralBaseline,
             .none:               return 0.5
        case .engagedFocused:     return 0.2
        case .highCognitiveLoad:  return 0.1
        }
    }

    /// Advances the EMA one window toward the current state's scalar. `alpha`
    /// is the fast time constant (larger ⇒ more responsive).
    public mutating func update(_ state: SpectralState?, alpha: Float) {
        let target = Self.scalar(for: state)
        value += alpha * (target - value)
    }
}
