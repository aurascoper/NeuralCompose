import XCTest
@testable import BCICore

/// Determinism-first coverage for `DeterministicSentenceEmbedder`, mirroring
/// the "same input → identical output, forever" guarantee that
/// `PlaybackEEGStreamTests` pins for normalized playback. The whole point of
/// this backend is reproducibility across process launches and CI runs, so the
/// suite leans on it heavily.
final class SentenceEmbedderTests: XCTestCase {

    private func embed(_ text: String, dimension: Int = 384, seed: UInt64 = 0) async throws -> Embedding {
        try await DeterministicSentenceEmbedder(dimension: dimension, seed: seed).encode(text)
    }

    private func norm(_ v: [Float]) -> Float {
        v.reduce(0) { $0 + $1 * $1 }.squareRoot()
    }

    // MARK: - Core invariants

    func testSameStringProducesIdenticalEmbedding() async throws {
        let a = try await embed("jaw clench")
        let b = try await embed("jaw clench")
        XCTAssertEqual(a, b)
    }

    func testTwoInstancesAgree() async throws {
        // Different instances, same config — reproducibility across launches
        // is simulated by two independent embedders.
        let a = try await DeterministicSentenceEmbedder().encode("rest")
        let b = try await DeterministicSentenceEmbedder().encode("rest")
        XCTAssertEqual(a.values, b.values)
    }

    func testOutputIsUnitNorm() async throws {
        for text in ["jaw clench", "rest", "hello world", "a"] {
            let e = try await embed(text)
            XCTAssertEqual(norm(e.values), 1.0, accuracy: 1e-4, "‖\(text)‖ should be 1")
        }
    }

    func testDimensionMatchesValuesCount() async throws {
        let e = try await embed("select", dimension: 128)
        XCTAssertEqual(e.dimension, 128)
        XCTAssertEqual(e.values.count, 128)
    }

    func testProvenanceIsPopulated() async throws {
        let e = try await embed("rest", seed: 123)
        XCTAssertEqual(e.modelID, "stub-hash-v1")
        XCTAssertEqual(e.version, "1")
        XCTAssertEqual(e.seed, 123)
    }

    // MARK: - Semantic-ish (compositional) behavior

    func testDistinctInputsDiffer() async throws {
        let a = try await embed("jaw clench")
        let b = try await embed("rest")
        XCTAssertLessThan(a.cosineSimilarity(to: b), 0.999, "distinct inputs should not be identical")
    }

    func testSharedTokensAreCloserThanUnrelated() async throws {
        // Compositional averaging: a shared token ("sleep") should pull two
        // phrases closer than an unrelated word.
        let sleep = try await embed("sleep")
        let deepSleep = try await embed("deep sleep")
        let banana = try await embed("banana")
        XCTAssertGreaterThan(
            sleep.cosineSimilarity(to: deepSleep),
            sleep.cosineSimilarity(to: banana),
            "'sleep' should be closer to 'deep sleep' than to 'banana'"
        )
    }

    // MARK: - Canonicalization

    func testCasingAndWhitespaceAreCanonicalized() async throws {
        let messy = try await embed("Jaw   Clench ")
        let clean = try await embed("jaw clench")
        XCTAssertEqual(messy.values, clean.values, "casing/whitespace must not change the vector")
    }

    func testUnicodeNormalizationMakesAccentsEqual() async throws {
        // "café" precomposed vs. with a combining acute accent (U+0301).
        let precomposed = try await embed("caf\u{00E9}")
        let combining = try await embed("cafe\u{0301}")
        XCTAssertEqual(precomposed.values, combining.values, "NFC should collapse accent forms")
    }

    // MARK: - Batch contract

    func testBatchPreservesOrder() async throws {
        let embedder = DeterministicSentenceEmbedder()
        let batch = try await embedder.encode(["alpha", "beta", "gamma"])
        let alpha = try await embedder.encode("alpha")
        let beta = try await embedder.encode("beta")
        let gamma = try await embedder.encode("gamma")
        XCTAssertEqual(batch, [alpha, beta, gamma], "results must be in input order")
    }

    func testDuplicatesAreIdenticalNoHiddenState() async throws {
        let batch = try await DeterministicSentenceEmbedder().encode(["rest", "rest", "rest"])
        XCTAssertEqual(batch[0], batch[1])
        XCTAssertEqual(batch[1], batch[2])
    }

    // MARK: - Empty / degenerate

    func testEmptyStringIsSafeAndDeterministic() async throws {
        let a = try await embed("")
        let b = try await embed("   ")   // whitespace-only canonicalizes to empty
        XCTAssertEqual(a.values, b.values, "empty and whitespace-only should match")
        XCTAssertEqual(norm(a.values), 1.0, accuracy: 1e-4, "empty must still be unit norm")
        XCTAssertFalse(a.values.contains { $0.isNaN }, "no NaN")
    }

    // MARK: - Injectable dimension

    func testVariousDimensionsAllNormalize() async throws {
        for d in [8, 16, 384, 768] {
            let e = try await embed("communicate", dimension: d)
            XCTAssertEqual(e.values.count, d)
            XCTAssertEqual(norm(e.values), 1.0, accuracy: 1e-4, "dim \(d) must be unit norm")
        }
    }

    // Golden-master lock on the text → vector mapping lives in
    // `SemanticReplayRegressionTests` (per-backend fixture, cosine matrix,
    // projection fingerprint). The full text→vector contract is now
    // pinned in one place rather than split between an inline constant
    // here and a larger fixture there.
}
