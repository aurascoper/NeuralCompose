import XCTest
@testable import BCILLM
@testable import BCICore

/// Tests the honesty gate directly against `SpectralStateEstimator.init`,
/// bypassing the subprocess-probe layer entirely (already covered by
/// `SpectralStateEstimatorFactoryTests`/`PredictorFactoryCrashSafetyTests`'
/// style) - the gate check runs before any `.safetensors` loading, so no
/// real weights are needed to exercise it, keeping this fast and
/// environment-independent.
final class SpectralStateEstimatorTests: XCTestCase {

    /// Minimal spy `SentenceEmbedder` - reports whatever `modelID` the test
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

    func testPrepareWindowSubstitutesBadChannelAndDemeansBeforeArtifactGate() {
        let n = 512
        let dc: Float = 820.0
        let healthyTP9: [Float] = (0..<n).map { i in dc + ((i % 2 == 0) ? 25.0 : -25.0) }
        let saturatedAF7: [Float] = (0..<n).map { i in dc + ((i % 2 == 0) ? 450.0 : -450.0) }
        let healthyAF8: [Float] = (0..<n).map { i in dc + ((i % 2 == 0) ? 20.0 : -20.0) }
        let healthyTP10: [Float] = (0..<n).map { i in dc + ((i % 2 == 0) ? 30.0 : -30.0) }

        let rawWindow = EEGWindow(
            samples: [healthyTP9, saturatedAF7, healthyAF8, healthyTP10],
            sampleRate: 256,
            endTimestamp: 2.0,
            sequence: 1
        )
        XCTAssertFalse(
            SpectralArtifactGate.isClean(rawWindow),
            "Raw window with +820 uV DC offset and saturated AF7 must fail SpectralArtifactGate before prepareWindow"
        )

        let prepared = SpectralStateEstimator.prepareWindow(rawWindow)
        XCTAssertTrue(
            SpectralArtifactGate.isClean(prepared),
            "After contralateral substitution of AF7<-AF8 and per-channel DC demeaning, prepared window must pass SpectralArtifactGate"
        )
        for ch in prepared.samples {
            let mean = ch.reduce(0, +) / Float(ch.count)
            XCTAssertEqual(mean, 0.0, accuracy: 0.05)
        }
        XCTAssertEqual(prepared.samples[1][0], 20.0, accuracy: 0.05)
        XCTAssertEqual(prepared.samples[1][1], -20.0, accuracy: 0.05)

        // When both partners (AF7 and AF8) contain NaN, substitution cannot rescue
        // them and SpectralArtifactGate.isClean must reject the prepared window.
        var nanChannel = healthyAF8
        nanChannel[10] = .nan
        let unsubstitutable = EEGWindow(
            samples: [healthyTP9, nanChannel, nanChannel, healthyTP10],
            sampleRate: 256,
            endTimestamp: 2.0,
            sequence: 2
        )
        let preparedBad = SpectralStateEstimator.prepareWindow(unsubstitutable)
        XCTAssertFalse(SpectralArtifactGate.isClean(preparedBad))
        XCTAssertTrue(preparedBad.samples[1][0].isFinite, "Finite samples around a single NaN must remain finite after demeaning")
        XCTAssertTrue(preparedBad.samples[1][10].isNaN)
    }
}
