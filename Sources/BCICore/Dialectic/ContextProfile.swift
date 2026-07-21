import Foundation

/// A named location in the dialectic's behavioral space — the tuning behind the
/// app's dialectical `HypnagogicMode`s (focused / reflective / contemplative;
/// `mirror` runs the non-dialectic reply loop and has no profile). A profile is
/// almost entirely a **preset over knobs the engine already has** (`Tuning` plus a
/// couple of loop-cadence fields); it introduces no new dynamics.
///
/// The names deliberately avoid sleep-stage / physiological language: they
/// describe how the *dialogue behaves*, not a state the Muse is claimed to
/// detect or induce.
///
///  - **focused** — coherent, grounded, conversational: resists drift, resolves
///    readily, rarely falls silent.
///  - **reflective** — the default dialectical behaviour: gentle semantic
///    exploration with tension that persists across turns.
///  - **contemplative** — *less, not more* (the point is non-elaboration, à la
///    zazen): low novelty pressure, synthesis suppressed, and a high tolerance
///    for unresolved tension and silence, at a slower cadence.
public enum ContextProfile: String, CaseIterable, Sendable, Identifiable {
    case focused, reflective, contemplative

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .focused:       return "Focused"
        case .reflective:    return "Reflective"
        case .contemplative: return "Contemplative"
        }
    }

    public var summary: String {
        switch self {
        case .focused:
            return "Coherent, grounded, conversational — resists drift, resolves readily, rarely silent."
        case .reflective:
            return "Gentle semantic exploration with tension that persists across turns (the default)."
        case .contemplative:
            return "Slower and quieter — low novelty pressure, synthesis suppressed, high tolerance for unresolved tension and silence."
        }
    }

    /// Competition + field + synthesis knobs for this profile. `reflective` is
    /// exactly the shipped defaults; the others move only existing parameters.
    public var tuning: DialecticalDynamics.Tuning {
        switch self {
        case .focused:
            return .init(
                highTension: 0.75,                                   // stalemate→silence is rare
                weights: .init(coherence: 1.2, resonance: 0.8, novelty: 0.4),  // ground, don't wander
                synthesisHighBar: 0.5, synthesisLowBar: 0.4, synthesisSustainK: 3, // resolve readily
                glossWind: 0.2                                        // grounded; EEG barely nudges
            )
        case .reflective:
            return .default
        case .contemplative:
            return .init(
                stalemateMargin: 0.12,                               // more turns count as undecided…
                highTension: 0.45,                                   // …and fall silent more readily
                weights: .init(coherence: 0.9, resonance: 0.6, novelty: 0.5),  // reduced novelty pressure
                synthesisHighBar: 0.8, synthesisLowBar: 0.65, synthesisSustainK: 6, // reluctant to resolve
                glossWind: 0.2
            )
        }
    }

    /// How long a run of dialectical silences may persist before a soft cue —
    /// contemplative tolerates the most.
    public var maxConsecutiveSilence: Int {
        switch self {
        case .focused:       return 2
        case .reflective:    return 3
        case .contemplative: return 6
        }
    }

    /// Pause between turns — contemplative breathes slowest.
    public var interTurnDelayNanos: UInt64 {
        switch self {
        case .focused:       return 2_000_000_000
        case .reflective:    return 3_000_000_000
        case .contemplative: return 6_000_000_000
        }
    }

    /// The introspective Witness runs ONLY for Reflective — this single line is
    /// where "Reflective is the introspective rung" is declared. Focused and
    /// Contemplative leave it off (no third cloud call). Reflective's `Tuning`
    /// stays `== .default`; the differentiation is this flag, not the dynamics.
    /// See `Sources/BCICore/Dialectic/WITNESS.md`.
    public var witnessEnabled: Bool { self == .reflective }

    /// A loop `Config` for this profile, preserving any non-cadence fields of
    /// `base` (listen timeout, tokens, prosody, cues, history window).
    public func loopConfig(base: HypnagogicDialecticLoop.Config = .init()) -> HypnagogicDialecticLoop.Config {
        HypnagogicDialecticLoop.Config(
            listenTimeout: base.listenTimeout,
            interTurnDelayNanos: interTurnDelayNanos,
            maxTokens: base.maxTokens,
            prosody: base.prosody,
            maxConsecutiveSilence: maxConsecutiveSilence,
            silenceCues: base.silenceCues,
            historyWindow: base.historyWindow,
            witnessEnabled: witnessEnabled
        )
    }
}
