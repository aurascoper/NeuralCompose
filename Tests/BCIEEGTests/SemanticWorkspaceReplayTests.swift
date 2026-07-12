import XCTest
import AppKit
@testable import BCICore
@testable import BCIEEG

/// "Freeze the whole visualization input" test. For each golden sentence,
/// drives a fresh `NeuralWorkspaceView` with the stub embedder wired up,
/// waits one poll tick, and asserts that the embedding the view stored in
/// `latestEmbedding` exactly matches the fixture's `embedding` entry.
///
/// Reads the same shared fixture as `SemanticReplayRegressionTests` (in
/// BCICoreTests) via `#filePath` — no schema duplication, no separate
/// `Bundle.module` resource. If the fixture moves, both tests fail to
/// skip, which is the right signal.
///
/// Deliberately does NOT assert `embeddingNode.position`: the workspace
/// shell-normalizes the projected vector onto a fixed-radius shell and
/// adds a visual y-offset, so node position also encodes visual-tuning
/// constants that don't belong in the semantic fixture. A real
/// pixel/SSIM regression test is the right level for that and is a
/// separate follow-up.
@MainActor
final class SemanticWorkspaceReplayTests: XCTestCase {

    /// Walking up from `Tests/BCIEEGTests/<this file>` lands at the repo root.
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private var fixtureURL: URL {
        repoRoot.appendingPathComponent("Tests/Fixtures/semantic_stub_v1.json")
    }

    /// Subset of the BCICore fixture's schema — only the fields the
    /// workspace-level check needs. Kept in lockstep with the BCICore
    /// schema by hand (the alternative — duplicating the full Codable
    /// struct across two test targets — would couple the two tests'
    /// failure modes and pull `CryptoKit` into BCIEEG, which has no
    /// other reason to import it).
    private struct SentenceReplay: Codable {
        let text: String
        let embedding: [Float]
    }
    private struct SemanticReference: Codable {
        let model: String
        let dimension: Int
        let seed: UInt64
        let sentences: [SentenceReplay]
    }

    func testWorkspaceLatestEmbeddingMatchesFixture() async throws {
        guard let data = try? Data(contentsOf: fixtureURL) else {
            throw XCTSkip(
                "No committed fixture at \(fixtureURL.path). "
                + "Run `NEURALCOMPOSE_REGENERATE_SEMANTIC_REFERENCE=1 swift test --filter SemanticReplayRegressionTests` "
                + "to generate it."
            )
        }
        let fixture = try JSONDecoder().decode(SemanticReference.self, from: data)

        // Sanity: the fixture must be the stub backend, at the dim we
        // wired it for. A fixture for a different backend (`minilm`,
        // `bge`) would need a different embedder here; a different
        // dimension would need a different `DeterministicSentenceEmbedder`
        // init. Bail rather than silently producing a meaningless pass.
        guard fixture.model == "stub-hash-v1" else {
            throw XCTSkip("Fixture backend is \(fixture.model); this test only covers the stub.")
        }

        let embedder = DeterministicSentenceEmbedder(
            dimension: fixture.dimension,
            seed: fixture.seed
        )

        for sentence in fixture.sentences {
            let view = NeuralWorkspaceView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
            view.subscribeEmbeddings(
                provider: embedder,
                contextProvider: { sentence.text }
            )
            // The polling loop encodes once on its first iteration before
            // sleeping `interval`. The same 100ms wait that
            // `NeuralWorkspaceViewTests.testStoresSentenceEmbedderVectorForContext`
            // uses is the established pattern; if it ever flakes on slow
            // CI, swap for a poll(timeout:).
            try? await Task.sleep(nanoseconds: 100_000_000)

            let stored = try XCTUnwrap(
                view.latestEmbedding,
                "workspace did not store an embedding for \"\(sentence.text)\""
            )
            XCTAssertEqual(stored.values.count, sentence.embedding.count,
                           "embedding length mismatch for \"\(sentence.text)\"")
            // `XCTAssertEqual` for `[Float]` has no `accuracy:` overload;
            // zip + per-component is the pattern the BCICore regression
            // test uses (and keeps failure messages specific to the
            // index that drifted, rather than a single bool).
            for (k, (a, b)) in zip(stored.values, sentence.embedding).enumerated() {
                XCTAssertEqual(a, b, accuracy: 1e-5,
                               "workspace stored embedding[\(k)] drifted for \"\(sentence.text)\"")
            }
            XCTAssertEqual(stored.dimension, fixture.dimension)
            XCTAssertEqual(stored.modelID, fixture.model)

            view.cancelEmbeddingSubscription()
        }
    }
}
