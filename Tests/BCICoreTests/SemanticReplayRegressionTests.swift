import XCTest
import CryptoKit
@testable import BCICore

/// Golden replay for the semantic pipeline:
///     text -> SentenceEmbedder -> Embedding -> RandomProjectionProjector -> coords
///
/// The fixture (`Tests/Fixtures/semantic_stub_v1.json`) freezes three things,
/// in order of brittleness:
///   1. **Embeddings** — per-sentence vectors from `DeterministicSentenceEmbedder(dimension: 32, seed: 0)`.
///   2. **Cosine matrix** — pairwise similarities. Relationships are what the
///      workspace actually consumes; surviving a minor embedder change, they
///      still catch an accidental regression.
///   3. **Projection coordinates** — `RandomProjectionProjector.project(values)`
///      per sentence, exposing drift in the embedder, the projector, *or* the
///      projector seed in one shot.
///
/// Plus a SHA-256 **projection fingerprint** over the concatenated projection
/// coords — a single-value drift check that survives the JSON being moved
/// around, with the full JSON retained for debugging when it changes.
///
/// The fixture is **backend-namespaced** (`_stub_`, `_v1`) so a real
/// `CoreMLSentenceEmbedder` lands later as `semantic_minilm_v1.json` /
/// `semantic_bge_v1.json` under the same tests. A backend swap is not a
/// regression; a backend drifting over time is.
///
/// To regenerate (e.g. after a deliberate `version` bump on the stub):
///
///     NEURALCOMPOSE_REGENERATE_SEMANTIC_REFERENCE=1 \
///         swift test --filter SemanticReplayRegressionTests
///
/// then inspect `git diff Tests/Fixtures/semantic_stub_v1.json` and commit
/// if expected. BCICore stays framework-free — `CryptoKit` is a test-only
/// import for the fingerprint.
final class SemanticReplayRegressionTests: XCTestCase {

    // MARK: - Schema (mirrors the committed JSON; keep in lockstep with
    // the `SemanticReference` struct in any future tooling that reads
    // these fixtures — there is no other consumer in-tree today).

    private struct SentenceReplay: Codable, Equatable {
        let text: String
        let embedding: [Float]   // dim-32 stub vector
        let projection: [Float]  // 3, raw project() output
    }

    private struct SemanticReference: Codable, Equatable {
        let model: String              // "stub-hash-v1"
        let version: String            // "1"
        let seed: UInt64               // embedder seed 0
        let projectionSeed: UInt64     // 0x5EED_C0DE (RandomProjectionProjector default)
        let dimension: Int             // 32
        let sentences: [SentenceReplay]
        let cosineMatrix: [[Float]]
        let projectionFingerprint: String   // SHA-256 hex of concatenated projection coords
    }

    // MARK: - Fixtures + paths

    /// Walking up from `Tests/BCICoreTests/<this file>` lands at the repo root.
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private var fixtureURL: URL {
        repoRoot.appendingPathComponent("Tests/Fixtures/semantic_stub_v1.json")
    }

    private static let goldenSentences: [String] = [
        "sleep",
        "deep sleep",
        "light sleep",
        "dream",
        "jaw clench",
        "rest",
        "banana",
    ]

    // MARK: - Test

    func testSemanticGoldenReferenceMatchesPipeline() throws {
        let embedder = DeterministicSentenceEmbedder(dimension: 32, seed: 0)
        let projector = RandomProjectionProjector()   // default seed = 0x5EED_C0DE

        // 1. Build the current reference from the live pipeline.
        let computed = try Self.computeReference(
            sentences: Self.goldenSentences,
            embedder: embedder,
            projector: projector
        )

        // 2. Regenerate path: write the fixture, then self-skip.
        if ProcessInfo.processInfo.environment["NEURALCOMPOSE_REGENERATE_SEMANTIC_REFERENCE"] == "1" {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(computed)
            try FileManager.default.createDirectory(
                at: fixtureURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: fixtureURL)
            throw XCTSkip("Regenerated \(fixtureURL.path) — inspect the diff and commit if expected.")
        }

        // 3. Assert path: decode the committed fixture and compare.
        guard let expectedData = try? Data(contentsOf: fixtureURL) else {
            throw XCTSkip(
                "No committed reference at \(fixtureURL.path). "
                + "Run with NEURALCOMPOSE_REGENERATE_SEMANTIC_REFERENCE=1 to generate it."
            )
        }
        let expected = try JSONDecoder().decode(SemanticReference.self, from: expectedData)

        // 3a. Provenance — exact match. A change here means a new fixture
        // should be committed (deliberate version bump), not a silent drift.
        XCTAssertEqual(computed.model, expected.model)
        XCTAssertEqual(computed.version, expected.version)
        XCTAssertEqual(computed.seed, expected.seed)
        XCTAssertEqual(computed.projectionSeed, expected.projectionSeed)
        XCTAssertEqual(computed.dimension, expected.dimension)
        XCTAssertEqual(computed.model, "stub-hash-v1", "fixture is the stub-backend golden")
        XCTAssertEqual(computed.dimension, 32, "fixture is dim-32 by intent (not the prod 384)")

        XCTAssertEqual(computed.sentences.count, expected.sentences.count)
        XCTAssertEqual(computed.cosineMatrix.count, expected.cosineMatrix.count)

        // 3b. Per-sentence vectors: component-wise with a tight tolerance
        // (deterministic pipeline, but leave headroom for cross-platform
        // float ordering on different CI hosts).
        for (i, c) in computed.sentences.enumerated() {
            let e = expected.sentences[i]
            XCTAssertEqual(c.text, e.text, "sentence \(i) text changed")

            XCTAssertEqual(c.embedding.count, e.embedding.count)
            for k in 0..<c.embedding.count {
                XCTAssertEqual(
                    c.embedding[k], e.embedding[k], accuracy: 1e-5,
                    "embedding[\(i)][\(k)] drifted"
                )
            }

            // L2-normalized invariant (BCICore contract, but worth pinning
            // on the fixture itself: a non-unit-norm entry in the fixture
            // means the embedder stopped honoring the contract).
            XCTAssertEqual(Self.norm(c.embedding), 1.0, accuracy: 1e-4,
                           "sentence \(i) embedding not unit-norm")

            // Projection coords — 3D from RandomProjectionProjector.project(_:).
            XCTAssertEqual(c.projection.count, 3)
            for k in 0..<3 {
                XCTAssertEqual(
                    c.projection[k], e.projection[k], accuracy: 1e-5,
                    "projection[\(i)][\(k)] drifted"
                )
            }
        }

        // 3c. Cosine matrix: tolerance-based, since the matrix is the
        // semantic contract; a tiny embedder change should still pass.
        for i in 0..<computed.cosineMatrix.count {
            for k in 0..<computed.cosineMatrix[i].count {
                XCTAssertEqual(
                    computed.cosineMatrix[i][k],
                    expected.cosineMatrix[i][k],
                    accuracy: 1e-5,
                    "cosine[\(i)][\(k)] drifted"
                )
            }
        }

        // 3d. Fingerprint: recomputed from the projection coords (NOT the
        // fixture's pre-baked string) and compared as an exact string. This
        // catches any silent change to embedder / projector / seed in one
        // value, while the per-component asserts above pinpoint where.
        let actualFingerprint = Self.fingerprint(of: computed)
        XCTAssertEqual(actualFingerprint, expected.projectionFingerprint, "projection fingerprint drifted")
    }

    // MARK: - Relationship sanity (guards the compositional contract even
    // across an intentional regenerate).

    /// "sleep" shares the `sleep` token with "deep sleep" / "light sleep" /
    /// "dream" (compositional averaging). "banana" shares no tokens with any
    /// of them and should land further away. This is a behavior-level check
    /// independent of the exact vector values — survives a deliberate regen
    /// of the stub as long as the embedder's compositional structure is
    /// preserved.
    func testCompositionalClusteringHolds() async throws {
        let embedder = DeterministicSentenceEmbedder(dimension: 32, seed: 0)
        let sleep = try await embedder.encode("sleep")
        let deepSleep = try await embedder.encode("deep sleep")
        let banana = try await embedder.encode("banana")

        let shared = sleep.cosineSimilarity(to: deepSleep)
        let unrelated = sleep.cosineSimilarity(to: banana)
        XCTAssertGreaterThan(shared, unrelated,
                             "compositional cluster broken: cos(sleep, deep sleep)=\(shared) should exceed cos(sleep, banana)=\(unrelated)")
    }

    // MARK: - Pipeline

    private static func computeReference(
        sentences: [String],
        embedder: DeterministicSentenceEmbedder,
        projector: RandomProjectionProjector
    ) throws -> SemanticReference {
        // The embedder is `async` but `DeterministicSentenceEmbedder.encode`
        // does no real I/O — `texts.map { embed($0) }`. Drive it through a
        // detached Task and block on a semaphore; safe here because the
        // task never suspends on anything that would deadlock against the
        // thread we're blocking on. The boxed result is `@unchecked
        // Sendable` because the semaphore establishes the happens-before
        // edge between the writer (the Task) and the reader (the
        // post-wait code).
        final class Box: @unchecked Sendable {
            var result: [Embedding] = []
        }
        let box = Box()
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            do {
                box.result = try await embedder.encode(sentences)
            } catch {
                // Encoding can't throw today (DeterministicSentenceEmbedder
                // is total), but keep the catch rather than force-unwrap.
            }
            semaphore.signal()
        }
        semaphore.wait()
        let result = box.result

        let projections: [[Float]] = result.map { emb in
            let p = projector.project(emb.values)
            return [p.x, p.y, p.z]
        }

        // Pairwise cosine matrix. Embeddings are L2-normalized by contract,
        // so cosine is a plain dot product — same arithmetic as
        // `Embedding.cosineSimilarity(to:)`, just hand-rolled here so the
        // matrix is in the fixture as a single ordered structure.
        let n = result.count
        var matrix = Array(repeating: Array(repeating: Float(0), count: n), count: n)
        for i in 0..<n {
            for k in 0..<n {
                matrix[i][k] = result[i].cosineSimilarity(to: result[k])
            }
        }

        let replayed = zip(sentences, zip(result, projections)).map { text, pair in
            SentenceReplay(
                text: text,
                embedding: pair.0.values,
                projection: pair.1
            )
        }

        return SemanticReference(
            model: embedder.modelID,
            version: embedder.version,
            seed: 0,
            projectionSeed: 0x5EED_C0DE,
            dimension: 32,
            sentences: replayed,
            cosineMatrix: matrix,
            projectionFingerprint: fingerprint(projections: projections)
        )
    }

    private static func fingerprint(of reference: SemanticReference) -> String {
        fingerprint(projections: reference.sentences.map { $0.projection })
    }

    /// SHA-256 over each projection's Float `bitPattern` bytes, in fixture
    /// sentence order. Test-only import of CryptoKit; production code stays
    /// framework-free. Using `bitPattern` (not String) so the hash is
    /// platform-independent regardless of how the Float is rendered.
    private static func fingerprint(projections: [[Float]]) -> String {
        var hasher = SHA256()
        for coords in projections {
            for value in coords {
                var bits = value.bitPattern
                withUnsafeBytes(of: &bits) { buffer in
                    hasher.update(bufferPointer: buffer)
                }
            }
        }
        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func norm(_ v: [Float]) -> Float {
        v.reduce(0) { $0 + $1 * $1 }.squareRoot()
    }
}
