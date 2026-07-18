import XCTest
@testable import BCILLM
@testable import BCICore

/// Tests the honesty gate directly against `SpectralStateEstimator.init`,
/// bypassing the subprocess-probe layer entirely (already covered by
/// `SpectralStateEstimatorFactoryTests`/`PredictorFactoryCrashSafetyTests`'
/// style) — the gate check runs before any `.safetensors` loading, so no
/// real weights are needed to exercise it, keeping this fast and
/// environment-independent.
final class SpectralStateEstimatorTests: XCTestCase {

    /// Minimal spy `SentenceEmbedder` — reports whatever `modelID` the test
    /// wants without needing a real Core ML BGE model on disk.
    private struct FakeEmbedder: SentenceEmbedder {
        let modelID: String
        let dimension: Int = 384
        let version: String = "1"
        func encode(_ texts: [String]) async throws -> [Embedding] {
            texts.map { _ in
                Embedding(values: [Float](repeating: 0, count: dimension), modelID: modelID, dimension: dimension, version: version, seed: 0)
            }
        }
    }

    private func writeConfigAndMetadata(to directory: URL, targetSpace: String) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let config = """
            {"in_channels":4,"window_samples":512,"sample_rate":256.0,"out_dim":384,"hidden":64}
            """
        let descriptors = SpectralState.allCases.map { "\"\($0.descriptor)\"" }.joined(separator: ",")
        let metadata = """
            {"target_space":"\(targetSpace)","descriptors":[\(descriptors)]}
            """
        try config.write(to: directory.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)
        try metadata.write(to: directory.appendingPathComponent("metadata.json"), atomically: true, encoding: .utf8)
    }

    func testRefusesWhenTrainingSideTargetSpaceIsFakeAnchorFallback() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("spectral-honesty-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeConfigAndMetadata(to: dir, targetSpace: "random-fallback (NOT bge)")

        do {
            _ = try await SpectralStateEstimator(
                modelDirectory: dir, sentenceEmbedder: FakeEmbedder(modelID: "bge-small-en-v1.5")
            )
            XCTFail("expected init to throw for an untrusted (--allow-fake-anchors) anchor space")
        } catch let BCIError.embedderMetadataInvalid(_, reason) {
            XCTAssertTrue(reason.contains("untrusted anchor space"))
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testRefusesWhenLiveEmbedderIsNotRealBGE() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("spectral-honesty-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeConfigAndMetadata(to: dir, targetSpace: "bge:Models/bge-small-en-v1.5-hf")

        do {
            _ = try await SpectralStateEstimator(
                modelDirectory: dir, sentenceEmbedder: FakeEmbedder(modelID: "stub-hash-v1")
            )
            XCTFail("expected init to throw when the live embedder isn't the real BGE")
        } catch let BCIError.embedderMetadataInvalid(_, reason) {
            XCTAssertTrue(reason.contains("untrusted anchor space"))
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testDescriptorMismatchThrowsMetadataInvalid() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("spectral-honesty-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let config = """
            {"in_channels":4,"window_samples":512,"sample_rate":256.0,"out_dim":384,"hidden":64}
            """
        let metadata = """
            {"target_space":"bge:Models/bge-small-en-v1.5-hf","descriptors":["not a real descriptor"]}
            """
        try config.write(to: dir.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)
        try metadata.write(to: dir.appendingPathComponent("metadata.json"), atomically: true, encoding: .utf8)

        do {
            _ = try await SpectralStateEstimator(
                modelDirectory: dir, sentenceEmbedder: FakeEmbedder(modelID: "bge-small-en-v1.5")
            )
            XCTFail("expected init to throw for mismatched descriptors")
        } catch let BCIError.embedderMetadataInvalid(_, reason) {
            XCTAssertTrue(reason.contains("descriptors"))
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }
}
