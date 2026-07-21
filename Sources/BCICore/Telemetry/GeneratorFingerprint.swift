import Foundation

/// The runtime identity recorded on each `DialecticalTurnEvent`. A
/// thin wrapper over `GenerationMetadata` trimmed to the fields
/// the telemetry needs for cross-provider comparison: which
/// runtime, which transport, which provider, which model, which
/// prompt profile, which interaction style, and a hash of the
/// prompt bytes (so a regression in prompt-assembly is detectable
/// from the log alone, without re-running the session).
///
/// Why a separate struct (not just `GenerationMetadata`):
/// `GenerationMetadata` carries transient measurements
/// (`latencyMilliseconds`, `tokenCount`, `generationParameters`)
/// that are useful for run analysis but are NOT part of the
/// generator's identity. The fingerprint is the *identity*; the
/// measurements are the *facts about the run*. Splitting them
/// keeps the identity stable for cross-run comparison.
///
/// ADR-009 invariant #5: canonical benchmarks are immutable.
/// Provider comparisons MUST use canonical benchmark artifacts.
/// The fingerprint is what makes a recorded turn
/// attributable to a specific (runtime, transport, provider,
/// model, promptProfile, interactionStyle, promptHash) tuple,
/// so future cross-provider runs are directly comparable.
///
/// Backward-compat: this struct is `Optional` on
/// `DialecticalTurnEvent`. Old logs that predate the field
/// decode unchanged because `Codable` treats missing keys as
/// `nil` for `Optional` fields by default. New logs include
/// the fingerprint; the rollup can identify them.
public struct GeneratorFingerprint: Codable, Sendable, Equatable {
    public let runtime: String
    public let transport: String
    public let provider: String
    public let model: String
    public let promptProfile: String
    public let interactionStyle: String
    public let promptHash: String

    public init(
        runtime: String,
        transport: String,
        provider: String,
        model: String,
        promptProfile: String,
        interactionStyle: String,
        promptHash: String
    ) {
        self.runtime = runtime
        self.transport = transport
        self.provider = provider
        self.model = model
        self.promptProfile = promptProfile
        self.interactionStyle = interactionStyle
        self.promptHash = promptHash
    }

    /// The fingerprint derived from a `GenerationMetadata`. Drops
    /// the transient fields (`latencyMilliseconds`, `tokenCount`,
    /// `generationParameters`) and keeps the identity tuple. The
    /// inverse — `metadata(from:)` — is the convenience accessor
    /// downstream consumers use when they need the full metadata
    /// shape (e.g. for a `DialecticalTurnEvent` summary view).
    public init(_ metadata: GenerationMetadata) {
        self.runtime = metadata.runtime
        self.transport = metadata.transport
        self.provider = metadata.provider
        self.model = metadata.model
        self.promptProfile = metadata.promptProfile
        self.interactionStyle = metadata.interactionStyle
        self.promptHash = metadata.promptHash
    }
}
