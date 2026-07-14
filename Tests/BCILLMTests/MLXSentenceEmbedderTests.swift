import Foundation
import MLXEmbedders
import XCTest

@testable import BCICore
@testable import BCILLM

/// Seam-based tests for `MLXSentenceEmbedder` — everything here runs without
/// a model on disk and without evaluating a single `MLXArray`, so it passes
/// under plain `swift test` (no Xcode-built metallib required; MLX kernels
/// only load when arrays are evaluated).
///
/// The real-model path (load + encode + ADR-004 §3.1 invariants) is gated on
/// `NEURALCOMPOSE_MLX_EMBEDDER_MODEL_DIR` and needs an Xcode-built test run —
/// same gating convention as the MLX generation regression tests.
final class MLXSentenceEmbedderTests: XCTestCase {

    // MARK: - Pooling metadata parsing (pooling is metadata, never guessed)

    private func poolingConfig(
        cls: Bool = false, mean: Bool = false, max: Bool = false, last: Bool = false
    ) throws -> PoolingConfiguration {
        let json = """
            {
              "word_embedding_dimension": 384,
              "pooling_mode_cls_token": \(cls),
              "pooling_mode_mean_tokens": \(mean),
              "pooling_mode_max_tokens": \(max),
              "pooling_mode_lasttoken": \(last)
            }
            """
        return try JSONDecoder().decode(
            PoolingConfiguration.self, from: Data(json.utf8))
    }

    func testPoolingLabelPrecedenceMatchesMLXEmbedders() throws {
        XCTAssertEqual(MLXSentenceEmbedder.poolingLabel(for: try poolingConfig(cls: true)), "cls")
        XCTAssertEqual(MLXSentenceEmbedder.poolingLabel(for: try poolingConfig(mean: true)), "mean")
        XCTAssertEqual(MLXSentenceEmbedder.poolingLabel(for: try poolingConfig(max: true)), "max")
        XCTAssertEqual(MLXSentenceEmbedder.poolingLabel(for: try poolingConfig(last: true)), "last")
        XCTAssertEqual(MLXSentenceEmbedder.poolingLabel(for: try poolingConfig()), "first")
        // cls wins over mean when both are set — the precedence
        // MLXEmbedders.Pooling(config:) applies.
        XCTAssertEqual(
            MLXSentenceEmbedder.poolingLabel(for: try poolingConfig(cls: true, mean: true)), "cls")
    }

    func testDecodeToleratesOldFormatWithoutLasttokenKey() throws {
        // bge-small (and every pre-lasttoken sentence-transformers export)
        // omits pooling_mode_lasttoken; absent means false. MLXEmbedders'
        // strict Codable rejects the file — our tolerant decode must not.
        let oldFormat = """
            {
              "word_embedding_dimension": 384,
              "pooling_mode_cls_token": true,
              "pooling_mode_mean_tokens": false,
              "pooling_mode_max_tokens": false,
              "pooling_mode_mean_sqrt_len_tokens": false
            }
            """
        let config = try MLXSentenceEmbedder.decodePoolingConfiguration(
            from: Data(oldFormat.utf8))
        XCTAssertEqual(config.dimension, 384)
        XCTAssertFalse(config.poolingModeLastToken)
        XCTAssertEqual(MLXSentenceEmbedder.poolingLabel(for: config), "cls")
    }

    func testDecodeStillRequiresDimension() {
        // word_embedding_dimension has no safe default — a file without it
        // must fail, not guess.
        let noDimension = #"{"pooling_mode_mean_tokens": true}"#
        XCTAssertThrowsError(try MLXSentenceEmbedder.decodePoolingConfiguration(
            from: Data(noDimension.utf8)))
    }

    func testPoolingStrategyMatchesSentenceTransformersSemantics() throws {
        // "cls" maps to .first (raw position-0 hidden state) — NOT .cls,
        // whose preference for the BertModel pooler head (tanh(dense(cls)))
        // is a different vector than sentence-transformers cls pooling.
        XCTAssertEqual(MLXSentenceEmbedder.poolingStrategy(for: "cls"), .first)
        XCTAssertEqual(MLXSentenceEmbedder.poolingStrategy(for: "mean"), .mean)
        XCTAssertEqual(MLXSentenceEmbedder.poolingStrategy(for: "max"), .max)
        XCTAssertEqual(MLXSentenceEmbedder.poolingStrategy(for: "last"), .last)
        XCTAssertEqual(MLXSentenceEmbedder.poolingStrategy(for: "first"), .first)
    }

    func testMissingPoolingConfigThrowsMetadataInvalid() async {
        let bogusDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mlx-embedder-missing-\(UUID().uuidString)")
        do {
            _ = try await MLXSentenceEmbedder(modelDirectory: bogusDirectory)
            XCTFail("expected embedderMetadataInvalid")
        } catch let BCIError.embedderMetadataInvalid(path, reason) {
            XCTAssertTrue(path.contains("1_Pooling"))
            XCTAssertTrue(reason.contains("pooling is metadata"))
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    // MARK: - Numeric invariants (ADR-004 §3.1)

    func testL2NormalizedProducesUnitNorm() {
        let normalized = MLXSentenceEmbedder.l2Normalized([3, 4])
        XCTAssertNotNil(normalized)
        let norm = normalized!.reduce(Float(0)) { $0 + $1 * $1 }.squareRoot()
        XCTAssertEqual(norm, 1.0, accuracy: 1e-4)
        XCTAssertEqual(normalized![0], 0.6, accuracy: 1e-6)
        XCTAssertEqual(normalized![1], 0.8, accuracy: 1e-6)
    }

    func testL2NormalizedRejectsDegenerateVector() {
        XCTAssertNil(MLXSentenceEmbedder.l2Normalized([0, 0, 0]))
        XCTAssertNil(MLXSentenceEmbedder.l2Normalized([1e-8, -1e-8]))
    }

    func testAxisUnitVectorIsDeterministicAndUnitNorm() {
        let v = MLXSentenceEmbedder.axisUnitVector(dimension: 384)
        XCTAssertEqual(v.count, 384)
        XCTAssertEqual(v[0], 1)
        XCTAssertEqual(v.dropFirst().reduce(Float(0), +), 0)
    }

    // MARK: - Real-model invariants (env-gated; Xcode-built runs only)

    func testRealModelEncodeInvariants() async throws {
        guard let modelDir = ProcessInfo.processInfo
            .environment["NEURALCOMPOSE_MLX_EMBEDDER_MODEL_DIR"]
        else {
            throw XCTSkip("NEURALCOMPOSE_MLX_EMBEDDER_MODEL_DIR not set")
        }
        let embedder = try await MLXSentenceEmbedder(
            modelDirectory: URL(fileURLWithPath: modelDir))
        let texts = [
            "Turn the lights off before you leave the room.",
            "I would like a glass of water, please.",
            "",
        ]
        let embeddings = try await embedder.encode(texts)

        // Order preservation + one embedding per input.
        XCTAssertEqual(embeddings.count, texts.count)
        for embedding in embeddings {
            XCTAssertEqual(embedding.values.count, embedder.dimension)
            XCTAssertEqual(embedding.modelID, embedder.modelID)
            // Unit norm within 1e-4 (ADR-004 §2.1), finite everywhere —
            // including for the empty string.
            XCTAssertTrue(embedding.values.allSatisfy(\.isFinite))
            let norm = embedding.values.reduce(Float(0)) { $0 + $1 * $1 }.squareRoot()
            XCTAssertEqual(norm, 1.0, accuracy: 1e-4)
        }
        // Determinism: same input → same vector.
        let again = try await embedder.encode([texts[0]])
        XCTAssertEqual(again[0].values, embeddings[0].values)
    }
}
