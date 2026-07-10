import Foundation

/// Reduces an arbitrary-length embedding vector to a 3D point for spatial
/// visualization.
///
/// This is a *display* concern, deliberately decoupled from
/// `TokenEmbeddingProviding` (how the vector was produced) so the
/// visualization layer never has to change when the projection algorithm
/// does. Swapping the projector changes only the position encoding in a
/// scene — node brightness, edge thickness, and other signal encodings
/// stay wired to whatever they already represent.
///
/// Implementations: `RandomProjectionProjector` (default, no fitting
/// required). A `PCAProjector` (fits on an accumulated embedding corpus)
/// and a `UMAPProjector` (offline structure discovery, not a live-stream
/// fit) are anticipated future additions behind this same protocol.
public protocol EmbeddingProjecting: Sendable {
    /// Project `embedding` to a 3D point. Implementations should be
    /// deterministic for a given input so repeated runs are comparable.
    func project(_ embedding: [Float]) -> SIMD3<Float>
}

/// Fixed, seeded random (Rademacher) projection. Requires no fitting step:
/// it works immediately and identically whether `embedding` is a 16-float
/// stub vector or a 150,000-dimensional real MLX logits vector — same code
/// path, same cost profile (one matrix build the first time a given
/// dimension is seen, then a single dot product per call).
///
/// **This is a visualization convenience, not a semantically meaningful
/// embedding layout. Spatial proximity should not be interpreted as
/// evidence of semantic similarity** — a random projection approximately
/// preserves *relative distances* between points (Johnson–Lindenstrauss),
/// which is a much weaker property than "nearby points mean similar
/// things." Replace with a fitted projector (PCA, once an embedding corpus
/// exists to fit on) before drawing any conclusion from the layout itself.
public final class RandomProjectionProjector: EmbeddingProjecting, @unchecked Sendable {
    private let seed: UInt64
    private let lock = NSLock()
    private var matrix: [[Float]]?
    private var matrixDimension: Int = -1

    public init(seed: UInt64 = 0x5EED_C0DE) {
        self.seed = seed
    }

    public func project(_ embedding: [Float]) -> SIMD3<Float> {
        guard !embedding.isEmpty else { return SIMD3<Float>(repeating: 0) }

        lock.lock()
        if matrixDimension != embedding.count {
            matrix = Self.buildMatrix(dimension: embedding.count, seed: seed)
            matrixDimension = embedding.count
        }
        let rows = matrix!
        lock.unlock()

        var result = SIMD3<Float>(repeating: 0)
        for axis in 0..<3 {
            var acc: Float = 0
            let row = rows[axis]
            for i in 0..<embedding.count { acc += row[i] * embedding[i] }
            result[axis] = acc
        }
        return result
    }

    /// Rademacher (±scale) matrix, scaled by `1/sqrt(dimension)` — a
    /// standard Johnson–Lindenstrauss-style random projection basis. A
    /// dense matrix is fine at today's scale; if a future model's
    /// dimension makes the build cost noticeable, a structured/sparse
    /// projection would be the next step, not a change to this protocol.
    private static func buildMatrix(dimension: Int, seed: UInt64) -> [[Float]] {
        let scale: Float = 1.0 / Float(dimension).squareRoot()
        var generator = SplitMix64(seed: seed)
        return (0..<3).map { _ in
            (0..<dimension).map { _ in generator.next() % 2 == 0 ? scale : -scale }
        }
    }
}

/// Minimal deterministic PRNG (SplitMix64) used to expand a seed into a
/// reproducible sequence of matrix entries. Duplicated from the equivalent
/// private helper in `BCILLM/StubNextWordPredictor.swift` rather than
/// shared across the module boundary for a ten-line utility. Not
/// cryptographic.
private struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { self.state = seed }
    mutating func next() -> UInt64 {
        state = state &+ 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
