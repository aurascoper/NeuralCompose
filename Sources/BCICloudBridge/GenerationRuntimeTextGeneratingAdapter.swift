import BCICore
import Foundation

/// A `TextGenerating` adapter that wraps any `GenerationRuntime`
/// (and its fixed system prompt) so the existing
/// `HypnagogicDialecticLoop` — which depends on `TextGenerating`,
/// not `GenerationRuntime` — can use any of the new runtimes
/// without a loop refactor.
///
/// This is the *smallest* change to wire runtime selection into
/// the harness: the loop's interface stays exactly the same, and
/// every `GenerationRuntime` conformer (Claude, Ollama, future
/// transports) becomes a drop-in `TextGenerating` via this
/// adapter. The keep-bar is preserved: the bytes the transport
/// sees are unchanged (the adapter does NOT modify the prompt
/// text; it only shapes a `GenerationContext` and calls
/// `runtime.generate(prompt:context:)`).
///
/// The adapter is `Sendable` because both the wrapped runtime
/// (which is `Sendable`) and the `systemPrompt` (a `String`) are
/// safe to pass across actor boundaries; the actor isolation on
/// the loop side is unchanged.
public struct GenerationRuntimeTextGeneratingAdapter: MetadataPublishingTextGenerating {
    public nonisolated let isLive: Bool
    public nonisolated let modelIdentifier: String
    public nonisolated let systemPrompt: String

    private let runtime: any GenerationRuntime
    private let maxTokens: Int
    private let defaultTemperature: Double

    /// Optional callback fired after every `runtime.generate(...)` call
    /// with the runtime-published `GenerationMetadata`. The legacy
    /// `TextGenerating` seam stays `String`-typed so existing
    /// conformers are unaffected; consumers that need provenance
    /// (the dialectic loop's `log(...)` path, specifically) set
    /// this once at construction and the adapter fires it on every
    /// call. The closure captures the sink by reference; consumers
    /// that hold a strong reference back to the adapter should
    /// dispatch the metadata to a non-retaining object to avoid
    /// a retain cycle.
    public var onMetadata: (@Sendable (GenerationMetadata) -> Void)?

    public init(
        runtime: any GenerationRuntime,
        systemPrompt: String,
        maxTokens: Int = 256,
        defaultTemperature: Double = 0.7
    ) {
        self.runtime = runtime
        self.systemPrompt = systemPrompt
        self.isLive = runtime.isLive
        self.modelIdentifier = runtime.modelIdentifier
        self.maxTokens = maxTokens
        self.defaultTemperature = defaultTemperature
    }

    public func generate(
        prompt: String,
        maxTokens: Int,
        temperature: Double,
        cancellationID: UUID
    ) async throws -> String {
        try Task.checkCancellation()
        let context = GenerationContext(
            priorTurns: [],
            modelHints: ["cancellationID": cancellationID.uuidString],
            generationParameters: .init(
                temperature: temperature > 0 ? temperature : defaultTemperature,
                maxTokens: maxTokens > 0 ? maxTokens : self.maxTokens
            )
        )
        let result = try await runtime.generate(prompt: prompt, context: context)
        // Fire the metadata callback so consumers (the dialectic
        // loop) can record `generatorFingerprint` on the persisted
        // `DialecticalTurnEvent`. The callback runs synchronously
        // here; if a consumer needs to do expensive work, it should
        // dispatch off-thread itself. The `metadataSink` weak ref
        // is the standard pattern for breaking the retain cycle
        // when the sink is the same object that owns the adapter.
        onMetadata?(result.metadata)
        return result.text
    }
}
