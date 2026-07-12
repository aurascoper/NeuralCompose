import Foundation

/// A semantic vector for a piece of text, plus the cheap provenance needed to
/// tell one embedding space from another at replay/diagnostic time.
///
/// This is a *domain object*, deliberately not a raw `[Float]`: the values
/// travel with enough metadata (`modelID`, `version`, `seed`, `dimension`) to
/// answer "which backend produced this, and would a re-run reproduce it?"
/// without a separate side table. It is intentionally **not** the full
/// versioned-artifact machinery (model/tokenizer SHA256, runtime, cache keys)
/// — those are metadata to *add* to this struct when a second backend actually
/// exists, not an architectural layer to build now. See the semantic-embedding
/// scoping notes.
///
/// Distinct from `TokenEmbeddingProviding`'s `[Float]`, which is a diagnostic
/// logit vector with no semantic meaning; an `Embedding` is meant to carry
/// genuine sentence semantics (real once a Core ML/MLX backend lands; a
/// deterministic stand-in until then via `DeterministicSentenceEmbedder`).
public struct Embedding: Sendable, Equatable {
    /// The embedding itself. **Invariant: L2-normalized** (unit length), so
    /// `cosineSimilarity(to:)` is a plain dot product and downstream
    /// projection/clustering never has to re-normalize. Producers must
    /// guarantee this; see `DeterministicSentenceEmbedder`.
    public let values: [Float]

    /// Identifies the backend that produced this vector, e.g. `"stub-hash-v1"`.
    /// Two embeddings with different `modelID`s are not comparable even if
    /// their `dimension` matches.
    public let modelID: String

    /// `values.count`, stored so callers don't have to hold onto the array to
    /// know the space's dimensionality.
    public let dimension: Int

    /// Backend output-format version. Bump when a backend changes how it maps
    /// text → vector in a way that invalidates stored vectors. Extend the
    /// notion later with tokenizer/model hashes as *fields*, not layers.
    public let version: String

    /// Seed that (together with `modelID`/`version`) pins the vector for a
    /// deterministic backend. `stub-hash-v1` seed 0 and seed 123 are
    /// legitimately different embedding spaces — recording the seed is what
    /// lets replay tell them apart. Zero for backends with no seed concept.
    public let seed: UInt64

    public init(values: [Float], modelID: String, dimension: Int, version: String, seed: UInt64) {
        self.values = values
        self.modelID = modelID
        self.dimension = dimension
        self.version = version
        self.seed = seed
    }

    /// Cosine similarity to `other`. Because both operands are L2-normalized
    /// by the `values` invariant, this is just the dot product — no magnitude
    /// division. Returns 0 when the dimensions differ (incomparable spaces)
    /// rather than trapping.
    public func cosineSimilarity(to other: Embedding) -> Float {
        guard values.count == other.values.count else { return 0 }
        var acc: Float = 0
        for i in 0..<values.count { acc += values[i] * other.values[i] }
        return acc
    }
}
