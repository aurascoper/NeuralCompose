import XCTest
import AppKit
import BCICore
@testable import BCIEEG

/// Verifies the Stage 1c concept-node "resource budget" in `NeuralWorkspaceView`:
/// a spoken-node event places (or re-brightens) an id-keyed node whose brightness
/// decays every `recompute()` and whose pool is capacity-bounded. Drives the view
/// headless via the `testable*` seam, exactly like `NeuralWorkspaceViewTests`.
@MainActor
final class NeuralWorkspaceConceptNodeTests: XCTestCase {

    private func makeView() -> NeuralWorkspaceView {
        NeuralWorkspaceView(frame: NSRect(x: 0, y: 0, width: 400, height: 400))
    }

    private func embedding(_ values: [Float]) -> Embedding {
        Embedding(values: values, modelID: "test", dimension: values.count, version: "v1", seed: 0)
    }

    private func placeEvent(nodeID: String, turnIndex: Int) -> SpokenNodeEvent {
        SpokenNodeEvent(nodeID: nodeID, text: "utterance \(nodeID)",
                        embedding: embedding([0.3, -0.6, 0.1, 0.5, -0.2, 0.4, 0.15, -0.35]),
                        word: nil, turnIndex: turnIndex)
    }

    private func wordEvent(nodeID: String, turnIndex: Int, word: String) -> SpokenNodeEvent {
        SpokenNodeEvent(nodeID: nodeID, text: "utterance \(nodeID)",
                        embedding: embedding([0.3, -0.6, 0.1, 0.5, -0.2, 0.4, 0.15, -0.35]),
                        word: SpokenWord(text: word, characterOffset: 0), turnIndex: turnIndex)
    }

    func testPlaceEventCreatesBrightNode() {
        let view = makeView()
        XCTAssertEqual(view.testableConceptNodeCount(), 0)
        view.testableIngestSpokenNode(placeEvent(nodeID: "0", turnIndex: 0))
        XCTAssertEqual(view.testableConceptNodeCount(), 1)
        XCTAssertEqual(view.testableConceptBrightness(for: "0"), 1.0)
    }

    func testWordEventReBrightensExistingNodeWithoutDuplicating() {
        let view = makeView()
        view.testableIngestSpokenNode(placeEvent(nodeID: "3", turnIndex: 3))
        view.testableTriggerRecompute()  // one decay tick
        let afterDecay = try? XCTUnwrap(view.testableConceptBrightness(for: "3"))
        XCTAssertNotNil(afterDecay)
        XCTAssertLessThan(afterDecay!, 1.0)
        // A word event for the same utterance must re-brighten the SAME node.
        view.testableIngestSpokenNode(wordEvent(nodeID: "3", turnIndex: 3, word: "hello"))
        XCTAssertEqual(view.testableConceptNodeCount(), 1)
        XCTAssertEqual(view.testableConceptBrightness(for: "3"), 1.0)
    }

    func testBrightnessDecaysAndNodeIsEvictedWhenFaded() {
        let view = makeView()
        view.testableIngestSpokenNode(placeEvent(nodeID: "7", turnIndex: 7))
        // 0.985^n < 0.02 floor at n ≈ 259; 400 ticks removes it comfortably.
        for _ in 0..<400 { view.testableTriggerRecompute() }
        XCTAssertEqual(view.testableConceptNodeCount(), 0)
        XCTAssertNil(view.testableConceptBrightness(for: "7"))
    }

    func testEmptyEmbeddingProducesNoNode() {
        let view = makeView()
        let event = SpokenNodeEvent(nodeID: "x", text: "t", embedding: embedding([]),
                                    word: nil, turnIndex: 0)
        view.testableIngestSpokenNode(event)
        XCTAssertEqual(view.testableConceptNodeCount(), 0)
    }

    func testPoolIsBoundedByCapacity() {
        let view = makeView()
        view.conceptNodeCapacity = 3
        // Decay between inserts so brightnesses differ → the dimmest (oldest) is
        // the deterministic eviction victim; the pool never exceeds capacity.
        for i in 0..<6 {
            view.testableIngestSpokenNode(placeEvent(nodeID: "\(i)", turnIndex: i))
            view.testableTriggerRecompute()
        }
        XCTAssertLessThanOrEqual(view.testableConceptNodeCount(), 3)
        // The most-recently-placed node survived (it was never the dimmest).
        XCTAssertNotNil(view.testableConceptBrightness(for: "5"))
    }
}
