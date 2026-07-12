import XCTest
import CryptoKit
@testable import BCICore
@testable import BCIClassifier

/// Golden replay for the semantic pipeline, retargeted at the real Core ML
/// backend:
///     text -> CoreMLSentenceEmbedder -> Embedding -> RandomProjectionProjector -> coords
///
/// A **separate file** from `SemanticReplayRegressionTests.swift` by design
/// (ADR-004 §3.5 Gate 1 forbids editing that file for a backend
/// substitution) — structurally a duplicate, retargeted at
/// `Tests/Fixtures/semantic_bge_small_v1.json`. The stub's replay stays
/// frozen forever; this is independent evidence for a second backend.
///
/// Skipped (not failed) when `Models/BGE-small-en-v1.5` doesn't exist on
/// disk — no `.mlmodelc` ships in this repo (see `CLAUDE.md`). Run
/// `Scripts/convert-sentence-embedder.py --model BAAI/bge-small-en-v1.5`
/// first, then:
///
///     NEURALCOMPOSE_REGENERATE_BGE_REFERENCE=1 \
///         swift test --filter SemanticBGEReplayRegressionTests
final class SemanticBGEReplayRegressionTests: XCTestCase {

    // MARK: - Schema (identical shape to the stub's fixture — same
    // pipeline, different backend).

    private struct SentenceReplay: Codable, Equatable {
        let text: String
        let embedding: [Float]   // dim-384 BGE vector
        let projection: [Float]  // 3, raw project() output
    }

    private struct SemanticReference: Codable, Equatable {
        let model: String              // "bge-small-en-v1.5"
        let version: String            // "1"
        let seed: UInt64               // 0 — no seed concept for a real backend
        let projectionSeed: UInt64     // 0x5EED_C0DE (RandomProjectionProjector default)
        let dimension: Int             // 384
        let sentences: [SentenceReplay]
        let cosineMatrix: [[Float]]
        let projectionFingerprint: String
    }

    // MARK: - Fixtures + paths

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private var fixtureURL: URL {
        repoRoot.appendingPathComponent("Tests/Fixtures/semantic_bge_small_v1.json")
    }

    private var modelDirectory: URL {
        repoRoot.appendingPathComponent("Models/BGE-small-en-v1.5")
    }

    /// Same golden sentence set as the stub's fixture — same pipeline,
    /// same inputs, different backend.
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

    func testSemanticGoldenReferenceMatchesPipeline() async throws {
        guard let embedder = try? CoreMLSentenceEmbedder(modelDirectory: modelDirectory) else {
            throw XCTSkip(
                "No BGE model at \(modelDirectory.path). Run "
                + "Scripts/convert-sentence-embedder.py --model BAAI/bge-small-en-v1.5 first."
            )
        }
        let projector = RandomProjectionProjector()   // default seed = 0x5EED_C0DE

        // 1. Build the current reference from the live pipeline.
        let computed = try await Self.computeReference(
            sentences: Self.goldenSentences,
            embedder: embedder,
            projector: projector
        )

        // 2. Regenerate path: write the fixture, then self-skip.
        if ProcessInfo.processInfo.environment["NEURALCOMPOSE_REGENERATE_BGE_REFERENCE"] == "1" {
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
                + "Run with NEURALCOMPOSE_REGENERATE_BGE_REFERENCE=1 to generate it."
            )
        }
        let expected = try JSONDecoder().decode(SemanticReference.self, from: expectedData)

        // 3a. Provenance — exact match.
        XCTAssertEqual(computed.model, expected.model)
        XCTAssertEqual(computed.version, expected.version)
        XCTAssertEqual(computed.seed, expected.seed)
        XCTAssertEqual(computed.projectionSeed, expected.projectionSeed)
        XCTAssertEqual(computed.dimension, expected.dimension)
        XCTAssertEqual(computed.model, "bge-small-en-v1.5", "fixture is the BGE-backend golden")
        XCTAssertEqual(computed.dimension, 384, "fixture is dim-384, BGE-small's real dimension")

        XCTAssertEqual(computed.sentences.count, expected.sentences.count)
        XCTAssertEqual(computed.cosineMatrix.count, expected.cosineMatrix.count)

        // 3b. Per-sentence vectors.
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

            XCTAssertEqual(Self.norm(c.embedding), 1.0, accuracy: 1e-4,
                           "sentence \(i) embedding not unit-norm")

            XCTAssertEqual(c.projection.count, 3)
            for k in 0..<3 {
                XCTAssertEqual(
                    c.projection[k], e.projection[k], accuracy: 1e-5,
                    "projection[\(i)][\(k)] drifted"
                )
            }
        }

        // 3c. Cosine matrix.
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

        // 3d. Fingerprint.
        let actualFingerprint = Self.fingerprint(of: computed)
        XCTAssertEqual(actualFingerprint, expected.projectionFingerprint, "projection fingerprint drifted")
    }

    // MARK: - Relationship sanity (survives an intentional regenerate).

    func testCompositionalClusteringHolds() async throws {
        guard let embedder = try? CoreMLSentenceEmbedder(modelDirectory: modelDirectory) else {
            throw XCTSkip("No BGE model at \(modelDirectory.path).")
        }
        let sleep = try await embedder.encode("sleep")
        let deepSleep = try await embedder.encode("deep sleep")
        let banana = try await embedder.encode("banana")

        let shared = sleep.cosineSimilarity(to: deepSleep)
        let unrelated = sleep.cosineSimilarity(to: banana)
        XCTAssertGreaterThan(
            shared, unrelated,
            "compositional cluster broken: cos(sleep, deep sleep)=\(shared) should exceed cos(sleep, banana)=\(unrelated)"
        )
    }

    // MARK: - Pipeline

    private static func computeReference(
        sentences: [String],
        embedder: CoreMLSentenceEmbedder,
        projector: RandomProjectionProjector
    ) async throws -> SemanticReference {
        let result = try await embedder.encode(sentences)

        let projections: [[Float]] = result.map { emb in
            let p = projector.project(emb.values)
            return [p.x, p.y, p.z]
        }

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
            dimension: embedder.dimension,
            sentences: replayed,
            cosineMatrix: matrix,
            projectionFingerprint: fingerprint(projections: projections)
        )
    }

    private static func fingerprint(of reference: SemanticReference) -> String {
        fingerprint(projections: reference.sentences.map { $0.projection })
    }

    /// SHA-256 over each projection's Float `bitPattern` bytes, in fixture
    /// sentence order — identical scheme to the stub's fixture fingerprint.
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
