import Foundation

/// A contextual vector representation of text, for visualization and
/// diagnostics — not part of the composition/prediction pipeline.
///
/// This is deliberately the same isolation pattern as `NextWordPredicting`:
/// the only thing that crosses the `BCILLM` boundary is a plain `[Float]`,
/// never an MLX type. See the Package.swift comment on MLX isolation.
///
/// Implementations: `StubNextWordPredictor` returns a small deterministic
/// vector (a stand-in with no semantic meaning); `MLXNextWordPredictor`
/// returns the last-token logits from a forward pass. Note that this is a
/// *logit* vector (pre-softmax, vocabulary-dimensional), not a pre-projection
/// hidden state — mlx-swift-examples' `LanguageModel` protocol only exposes
/// final logits generically, with no architecture-independent way to reach
/// a model's internal hidden state. It's still a legitimate contextual
/// vector (two prompts that continue similarly will have similar logit
/// vectors), just not the same object as a transformer's residual-stream
/// embedding.
public protocol TokenEmbeddingProviding: Sendable {
    /// A contextual vector for `text`. Implementations may cache or batch
    /// as they see fit; callers should not assume a fixed dimensionality
    /// across different implementations (stub vs. MLX vectors differ in
    /// both size and meaning).
    func embedding(for text: String) async throws -> [Float]
}
