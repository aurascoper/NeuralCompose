import Foundation

/// A refinement of `TextGenerating` for runtimes that publish structured
/// `GenerationMetadata` alongside their text output. Conformers
/// (today: `GenerationRuntimeTextGeneratingAdapter` in `BCICloudBridge`;
/// in the future: any runtime that wraps a `GenerationRuntime` from
/// `Sources/BCICore/Protocols/GenerationRuntime.swift`) fire the
/// `onMetadata` callback after every `generate(...)` call with the
/// runtime-published metadata. Consumers (e.g. the dialectic loop's
/// `log(...)` path) subscribe once at construction to receive
/// provenance for every turn.
///
/// **Why a refinement protocol rather than widening `TextGenerating`:**
/// the legacy `ClaudeCLIGenerator` and other pre-runtime-abstraction
/// conformers don't publish metadata — they only return `String` —
/// and forcing them to adopt a metadata field would be a breaking
/// change with no benefit. Refinement lets the loop type-check
/// (`as? MetadataPublishingTextGenerating`) and gracefully no-op for
/// legacy conformers.
///
/// The callback closure captures the sink by reference. Consumers
/// that hold a strong reference back to the conformer should
/// dispatch the metadata to a non-retaining object (or use
/// `[weak self]` in the closure) to avoid a retain cycle.
///
/// ADR-009 invariant #2 (runtime SHALL NOT modify semantic intent)
/// is preserved: this protocol only carries provenance, not
/// semantic state.
public protocol MetadataPublishingTextGenerating: TextGenerating {
    /// Set this to receive the runtime-published metadata after
    /// every `generate(...)` call. The callback runs synchronously
    /// on the same task that called `generate(...)`. Set to `nil`
    /// to detach. Marked `@Sendable` so the conformer can remain
    /// `Sendable` (the adapter is held across actor boundaries).
    /// The closure captures the sink by reference. Consumers that
    /// hold a strong reference back to the conformer should use
    /// `[weak self]` in the closure to avoid a retain cycle.
    ///
    /// ADR-009 invariant #2 (runtime SHALL NOT modify semantic
    /// intent) is preserved: this callback only carries provenance,
    /// not semantic state.
    var onMetadata: (@Sendable (GenerationMetadata) -> Void)? { get set }
}
