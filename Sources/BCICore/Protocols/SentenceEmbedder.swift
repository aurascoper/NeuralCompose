import Foundation

/// Produces genuinely semantic sentence embeddings from text.
///
/// This is the contract a real Core ML/MLX sentence encoder (BGE/E5/MiniLM)
/// will conform to; today the only implementation is
/// `DeterministicSentenceEmbedder`, a dependency-free stand-in. It supersedes
/// `TokenEmbeddingProviding` as the workspace's vector source —
/// `TokenEmbeddingProviding` returns diagnostic *logit* vectors with no
/// semantic meaning (see that protocol's doc comment), whereas a
/// `SentenceEmbedder` is meant to place semantically similar text near each
/// other.
///
/// Same isolation discipline as the rest of BCICore's protocols: `async
/// throws`, `Sendable`, and **only plain-Swift types cross the boundary** — an
/// eventual `CoreMLSentenceEmbedder`/`MLXSentenceEmbedder` returns `Embedding`
/// values, never an `MLMultiArray` or `MLXArray`. See the Package.swift note
/// on MLX isolation.
///
/// The `modelID`/`dimension`/`version` properties describe the *backend*; the
/// same-named fields on `Embedding` describe a produced *artifact*. The
/// duplication is intentional — it keeps diagnostics and replay logging clean
/// (you can log which backend is live without having encoded anything yet).
public protocol SentenceEmbedder: Sendable {
    /// Identifies this backend, e.g. `"stub-hash-v1"`. Stamped onto every
    /// `Embedding` this backend produces.
    var modelID: String { get }

    /// Dimensionality of the vectors this backend produces.
    var dimension: Int { get }

    /// Backend output-format version, stamped onto produced `Embedding`s.
    var version: String { get }

    /// Encode a batch of strings, returning one `Embedding` per input **in
    /// input order** (index `i` of the result is the embedding of `texts[i]`).
    /// Batch-first so a future neural backend isn't forced to spin up the ANE
    /// once per string. Every returned `Embedding` satisfies the L2-normalized
    /// `values` invariant.
    func encode(_ texts: [String]) async throws -> [Embedding]
}

public extension SentenceEmbedder {
    /// Convenience for the common single-string case; delegates to the
    /// batch `encode(_:)`.
    func encode(_ text: String) async throws -> Embedding {
        let results = try await encode([text])
        // encode([text]) returns exactly one element by contract; the
        // fallback keeps this total rather than force-unwrapping.
        guard let first = results.first else {
            return Embedding(
                values: [Float](repeating: 0, count: dimension),
                modelID: modelID, dimension: dimension, version: version, seed: 0
            )
        }
        return first
    }
}
