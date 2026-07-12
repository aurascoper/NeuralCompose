import XCTest
@testable import BCICore
@testable import BCIClassifier

/// No `.mlmodelc` ships in this repo (models are never committed — see
/// `CLAUDE.md`), so there is no happy-path encode test here, matching how
/// `CoreMLIntentClassifier` has none either. This suite pins the
/// missing-model / invalid-metadata failure modes instead.
final class CoreMLSentenceEmbedderTests: XCTestCase {

    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func makeTempDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("CoreMLSentenceEmbedderTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func writeMetadata(_ json: String, to dir: URL) throws {
        try json.write(to: dir.appendingPathComponent("metadata.json"), atomically: true, encoding: .utf8)
    }

    func testMissingModelDirectoryThrows() {
        let nonexistent = FileManager.default.temporaryDirectory
            .appendingPathComponent("does-not-exist-\(UUID().uuidString)")
        XCTAssertThrowsError(try CoreMLSentenceEmbedder(modelDirectory: nonexistent)) { error in
            guard case BCIError.embedderModelMissing = error else {
                return XCTFail("expected embedderModelMissing, got \(error)")
            }
        }
    }

    func testMalformedMetadataJSONThrows() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeMetadata("not json", to: dir)

        XCTAssertThrowsError(try CoreMLSentenceEmbedder(modelDirectory: dir)) { error in
            guard case BCIError.embedderMetadataInvalid = error else {
                return XCTFail("expected embedderMetadataInvalid, got \(error)")
            }
        }
    }

    func testDimensionMismatchThrows() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeMetadata("""
        {"model":"test","revision":"main","pooling":"cls","dimension":256,"tokenizer":"tokenizer.json","converted_with":"test"}
        """, to: dir)

        XCTAssertThrowsError(try CoreMLSentenceEmbedder(modelDirectory: dir)) { error in
            guard case BCIError.embedderMetadataInvalid = error else {
                return XCTFail("expected embedderMetadataInvalid, got \(error)")
            }
        }
    }

    func testInvalidPoolingValueThrows() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeMetadata("""
        {"model":"test","revision":"main","pooling":"max","dimension":384,"tokenizer":"tokenizer.json","converted_with":"test"}
        """, to: dir)

        XCTAssertThrowsError(try CoreMLSentenceEmbedder(modelDirectory: dir)) { error in
            guard case BCIError.embedderMetadataInvalid = error else {
                return XCTFail("expected embedderMetadataInvalid, got \(error)")
            }
        }
    }

    func testValidMetadataButMissingModelFileThrows() throws {
        // metadata.json + tokenizer.json are both valid, but no
        // model.mlmodelc/.mlpackage is present — the model file itself is
        // the thing that's missing.
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeMetadata("""
        {"model":"BAAI/bge-small-en-v1.5","revision":"main","pooling":"cls","dimension":384,"tokenizer":"tokenizer.json","converted_with":"test"}
        """, to: dir)
        try FileManager.default.copyItem(
            at: repoRoot.appendingPathComponent("Tests/Fixtures/tokenizer_test.json"),
            to: dir.appendingPathComponent("tokenizer.json")
        )

        XCTAssertThrowsError(try CoreMLSentenceEmbedder(modelDirectory: dir)) { error in
            guard case BCIError.embedderModelMissing = error else {
                return XCTFail("expected embedderModelMissing, got \(error)")
            }
        }
    }
}
