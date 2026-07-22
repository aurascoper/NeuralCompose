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

    /// Reference-typed storage for the metadata callback. Required
    /// because `GenerationRuntimeTextGeneratingAdapter` is a `struct`
    /// and `any TextGenerating` is an existential — opening the box
    /// via `as?` and assigning to the cast local mutates a *copy*,
    /// not the value held by the loop's `let generator` property.
    /// Storing the callback in a class-typed box means the same
    /// box is shared across all copies, so the loop's
    /// `attachMetadataCaptureFromAdapter()` writes the callback
    /// to a box that the loop's stored copy will read on the
    /// next `generate(...)` call. The box is created once at
    /// adapter init and never replaced; consumers never see it.
    private let metadataBox = MetadataCallbackBox()

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
    public var onMetadata: (@Sendable (GenerationMetadata) -> Void)? {
        get { metadataBox.callback }
        set { metadataBox.callback = newValue }
    }

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

/// Reference-typed storage for the metadata callback. Required
/// because `GenerationRuntimeTextGeneratingAdapter` is a `struct`
/// and `any TextGenerating` opens via `as?` into a *mutable copy*,
/// so a callback set on the local cast is invisible to the
/// original `let`-stored adapter. The class box is shared across
/// all copies; the adapter's `onMetadata` property reads and
/// writes through it, so any holder of any copy sees the same
/// callback. The box is private; consumers only see
/// `onMetadata` (the protocol requirement).
///
/// `@unchecked Sendable` because the `var` is protected by the
/// implicit serialization: writes happen on the loop's actor
/// (via `attachMetadataCaptureFromAdapter`), reads happen on the
/// same task that called `generate(...)` (which is also on the
/// loop's actor). The compiler can't prove this so we mark
/// unchecked; in practice there is no data race.
private final class MetadataCallbackBox: @unchecked Sendable {
    var callback: (@Sendable (GenerationMetadata) -> Void)?
}
