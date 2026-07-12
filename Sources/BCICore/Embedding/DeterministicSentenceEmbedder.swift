import Foundation

/// A dependency-free `SentenceEmbedder` that maps text to a stable vector with
/// no model at all — the stub that lets the whole embedding→projection→3D
/// workspace pipeline run (and be regression-tested) before a real Core ML/MLX
/// encoder exists.
///
/// **Fully reproducible across process launches and CI runs.** That is the
/// whole point and it drives two deliberate choices:
///
///  1. Hashing uses **FNV-1a over UTF-8 bytes**, never `String.hashValue` /
///     `Hasher` — Swift randomizes those per process, which would silently
///     rotate the 3D projection on every CI boot and break golden replay.
///  2. Text is **canonicalized before hashing** (Unicode NFC → locale-
///     independent lowercase → whitespace-collapsed), so a vector can't depend
///     on invisible input differences (a combining vs. precomposed accent,
///     double spaces, trailing whitespace, casing).
///
/// It is *compositional* rather than a single opaque hash: it hashes each
/// whitespace token to a fixed random direction and averages them. That buys a
/// little real structure for free — "sleep" and "deep sleep" land closer than
/// "sleep" and "banana" — which makes the workspace behave more like it will
/// with a real encoder, without introducing any ML or dependency. It is still
/// **not** semantically meaningful in any linguistic sense; treat spatial
/// proximity as decorative until a real backend replaces this.
public struct DeterministicSentenceEmbedder: SentenceEmbedder {
    public let modelID = "stub-hash-v1"
    public let version = "1"
    public let dimension: Int
    private let seed: UInt64

    public init(dimension: Int = 384, seed: UInt64 = 0) {
        precondition(dimension > 0, "embedding dimension must be positive")
        self.dimension = dimension
        self.seed = seed
    }

    public func encode(_ texts: [String]) async throws -> [Embedding] {
        // Order-preserving and stateless: index i maps to texts[i], and the
        // same string always yields the same vector regardless of neighbors.
        texts.map { embed($0) }
    }

    // MARK: - Core

    private func embed(_ text: String) -> Embedding {
        let tokens = Self.canonicalTokens(text)

        // Sum fixed per-token direction vectors, then L2-normalize the mean.
        var acc = [Float](repeating: 0, count: dimension)
        for token in tokens {
            let vec = tokenVector(for: token)
            for i in 0..<dimension { acc[i] += vec[i] }
        }

        var values = Self.normalized(acc)
        if values == nil {
            // Empty / whitespace-only input, or a (measure-zero) exact
            // cancellation of token directions. Fall back to a single stable
            // unit vector derived from the whole canonical string ("" for
            // empty input) so the result is always finite, unit-length, and
            // deterministic — never NaN or a zero vector.
            let whole = tokens.joined(separator: " ")
            values = Self.normalized(tokenVector(for: whole)) ?? Self.axisUnitVector(dimension: dimension)
        }

        return Embedding(
            values: values!,
            modelID: modelID,
            dimension: dimension,
            version: version,
            seed: seed
        )
    }

    /// A fixed pseudo-random direction for `token`, seeded so the stream
    /// depends on both the token and this embedder's `seed` (different seeds
    /// give genuinely different spaces — SplitMix64 avalanches the XOR).
    private func tokenVector(for token: String) -> [Float] {
        var generator = SplitMix64(seed: Self.fnv1a(token) ^ seed)
        return (0..<dimension).map { _ in
            // Uniform in [-1, 1); mirrors StubNextWordPredictor's stub vector.
            Float(generator.next() % 2000) / 1000.0 - 1.0
        }
    }

    // MARK: - Text canonicalization

    /// NFC → locale-independent lowercase → split on Unicode whitespace
    /// (which also trims and collapses runs). Returns the ordered tokens.
    static func canonicalTokens(_ text: String) -> [String] {
        let canonical = text.precomposedStringWithCanonicalMapping.lowercased()
        return canonical
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
    }

    // MARK: - Numeric helpers

    /// L2-normalize, or `nil` if the vector's norm is too small to divide by
    /// safely (empty or exactly-cancelling input).
    static func normalized(_ v: [Float]) -> [Float]? {
        var sumSq: Float = 0
        for x in v { sumSq += x * x }
        let norm = sumSq.squareRoot()
        guard norm > 1e-6 else { return nil }
        return v.map { $0 / norm }
    }

    /// Last-resort deterministic unit vector (first axis) for the pathological
    /// case where even the whole-string fallback fails to normalize. Unit
    /// length by construction.
    private static func axisUnitVector(dimension: Int) -> [Float] {
        var v = [Float](repeating: 0, count: dimension)
        v[0] = 1
        return v
    }

    /// Stable FNV-1a over the string's UTF-8 bytes. Execution-independent,
    /// unlike `String.hashValue`. Matches the helper in
    /// `BCILLM/StubNextWordPredictor.swift`.
    static func fnv1a(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325 // FNV offset basis
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3 // FNV prime
        }
        return hash
    }
}

/// Minimal deterministic PRNG (SplitMix64), used to expand a hash seed into a
/// reproducible float sequence. Duplicated from the equivalent private helpers
/// in `EmbeddingProjecting.swift` and `BCILLM/StubNextWordPredictor.swift`
/// rather than shared for a ten-line utility. Not cryptographic.
private struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { self.state = seed }
    mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
