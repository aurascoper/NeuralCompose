import Foundation

/// Opt-in per-cycle trace of the `SpokenGenerationLoop` — one record of what fed
/// a cycle versus what came out of it. It exists to answer a single diagnostic
/// question the loop otherwise cannot: is a quiet or repetitive run **broken**
/// (generation/speech erroring) or merely **starved** (a stable input faithfully
/// producing a stable output)? Those call for opposite fixes.
///
/// The two EEG-derived knobs (`temperature`, `styleInstruction`, both from
/// `GenerationAdaptation` / signal quality) are logged as an *independent* stream
/// alongside the text, so a degraded output can be bisected into a decode artifact
/// vs. an upstream signal drop without touching any adaptive logic. Text + scalars
/// only, never embeddings — parallel to `DialecticalTurnEvent`, not an extension of
/// it. Written only when a sink is injected (see `SpokenGenerationTraceLogging`).
public struct SpokenGenerationTraceEvent: Codable, Sendable, Equatable {

    /// Monotonic cycle counter for this loop run (starts at 0).
    public let index: Int
    /// Signal-quality-derived sampling temperature used to generate this cycle.
    public let temperature: Double
    /// Signal-quality-derived soft-priming prefix prepended to the seed (may be
    /// empty when signal quality warrants no styling).
    public let styleInstruction: String
    /// The generation token budget for this cycle (`Config.maxTokens`).
    public let maxTokens: Int
    /// Whether the optional `DialecticEngine` refine pass actually ran this cycle.
    public let usedDialectic: Bool
    /// The fully assembled prompt that went in — the "what fed it" half. A run of
    /// identical prompts across cycles is the signature of a *starved* loop.
    public let prompt: String
    /// The raw generated text — the "what came out" half. `nil` when generation
    /// (or the refine pass) threw before producing text; see `error`.
    public let generated: String?
    /// Whether a non-empty utterance was actually voiced this cycle. `false` with a
    /// non-nil `generated` means the model produced only whitespace.
    public let spoke: Bool
    /// The description of a swallowed non-cancellation failure (generation or
    /// speech), or `nil` on a clean cycle. This is what makes the *broken* case
    /// visible — the loop otherwise silently retries and surfaces nothing.
    public let error: String?

    public init(
        index: Int,
        temperature: Double,
        styleInstruction: String,
        maxTokens: Int,
        usedDialectic: Bool,
        prompt: String,
        generated: String?,
        spoke: Bool,
        error: String?
    ) {
        self.index = index
        self.temperature = temperature
        self.styleInstruction = styleInstruction
        self.maxTokens = maxTokens
        self.usedDialectic = usedDialectic
        self.prompt = prompt
        self.generated = generated
        self.spoke = spoke
        self.error = error
    }
}

/// Sink for `SpokenGenerationTraceEvent`s — the opt-in persistence seam, parallel
/// to `DialecticalTurnLogging`. The default `NullSpokenGenerationTraceLogger`
/// drops everything, so the loop traces nothing unless a real sink is injected.
public protocol SpokenGenerationTraceLogging: Sendable {
    func log(_ event: SpokenGenerationTraceEvent) async
}

public struct NullSpokenGenerationTraceLogger: SpokenGenerationTraceLogging {
    public init() {}
    public func log(_ event: SpokenGenerationTraceEvent) async {}
}
