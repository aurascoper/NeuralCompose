import XCTest
import Foundation
@testable import BCICore

/// Milestone 3 — the semantic-graph memory and the emergent-synthesis gate.
final class DialecticalMemoryTests: XCTestCase {

    private func emb(_ v: [Float]) -> Embedding {
        let norm = sqrtf(v.reduce(0) { $0 + $1 * $1 })
        let unit = norm > 0 ? v.map { $0 / norm } : v
        return Embedding(values: unit, modelID: "t", dimension: v.count, version: "1", seed: 0)
    }

    // MARK: - SemanticGraph

    func testGraphLinksSimilarNodesAndRanksByProximity() {
        var g = SemanticGraph(capacity: 8, edgeThreshold: 0.9)
        g.insert(text: "sea", embedding: emb([1, 0]), turnIndex: 0, kind: .heard)
        g.insert(text: "ocean", embedding: emb([0.98, 0.2]), turnIndex: 1, kind: .reply)   // near "sea"
        g.insert(text: "clock", embedding: emb([0, 1]), turnIndex: 2, kind: .reply)        // orthogonal

        XCTAssertEqual(g.edges.count, 1, "only the two near vectors are linked above threshold")
        let near = g.nearestPriorNodes(to: emb([1, 0]), limit: 2)
        XCTAssertEqual(near.first?.text, "sea", "the closest prior idea ranks first")
        XCTAssertEqual(near.map(\.text), ["sea", "ocean"], "ranked by descending similarity")
    }

    func testGraphEvictsOldestBeyondCapacity() {
        var g = SemanticGraph(capacity: 2, edgeThreshold: 0.5)
        g.insert(text: "a", embedding: emb([1, 0]), turnIndex: 0, kind: .heard)
        g.insert(text: "b", embedding: emb([0, 1]), turnIndex: 1, kind: .heard)
        g.insert(text: "c", embedding: emb([1, 1]), turnIndex: 2, kind: .heard)
        XCTAssertEqual(g.nodes.map(\.text), ["b", "c"], "the oldest node is evicted at capacity")
        XCTAssertFalse(g.edges.contains { $0.a == 0 || $0.b == 0 }, "its edges go with it")
    }

    // MARK: - Derived slow-clock quantities

    func testEntropyAndDriftReflectReplyMovement() {
        var focused = DialecticalMemory(historyWindow: 8)
        focused.recordReply(text: "x", embedding: emb([1, 0]), turnIndex: 0)
        focused.recordReply(text: "x2", embedding: emb([1, 0.02]), turnIndex: 1)  // barely moved

        var wandering = DialecticalMemory(historyWindow: 8)
        wandering.recordReply(text: "a", embedding: emb([1, 0]), turnIndex: 0)
        wandering.recordReply(text: "b", embedding: emb([0, 1]), turnIndex: 1)     // jumped

        XCTAssertLessThan(focused.entropy, wandering.entropy, "a focused dialogue has lower entropy")
        XCTAssertLessThan(focused.drift, wandering.drift, "…and lower drift")
    }

    // MARK: - Synthesis gate

    func testResurfacedBridgingIdeaBecomesSynthesisCandidate() {
        var m = DialecticalMemory(historyWindow: 8, tensionCeiling: 0.35)
        // A prior idea sitting close to both of the poles we'll present later.
        m.recordHeard(text: "the tide remembers", embedding: emb([1, 1, 0]), turnIndex: 0)

        let thesis = emb([1, 0, 0])
        let antithesis = emb([0, 1, 0])
        let synth = m.synthesisCandidate(thesis: thesis, antithesis: antithesis, tuning: .default)
        XCTAssertEqual(synth?.text, "the tide remembers",
                       "an old idea that reconciles both poles resurfaces as the synthesis")
        XCTAssertEqual(synth?.roleID, "synthesis")
    }

    func testNoBridgingIdeaMeansNoSynthesis() {
        var m = DialecticalMemory(historyWindow: 8, tensionCeiling: 0.35)
        // A prior idea aligned with only ONE pole — reconciles nothing.
        m.recordHeard(text: "only thesis", embedding: emb([1, 0, 0]), turnIndex: 0)
        let synth = m.synthesisCandidate(thesis: emb([1, 0, 0]), antithesis: emb([0, 1, 0]),
                                         tuning: .default)
        XCTAssertNil(synth, "an idea close to one pole only does not clear the strict bar")
    }

    func testSustainedConvergenceLowersTheSynthesisBar() {
        // An idea whose reconciliation score sits between the low and high bars
        // (min-sim ≈ 0.57): barred while opposed, admitted once converged.
        let bridge = emb([1, 0.15, 0])
        let thesis = emb([1, 0, 0])
        let antithesis = emb([0, 1, 0])

        var opposed = DialecticalMemory(historyWindow: 8, tensionCeiling: 0.35)
        opposed.recordHeard(text: "bridge", embedding: bridge, turnIndex: 0)
        XCTAssertNil(opposed.synthesisCandidate(thesis: thesis, antithesis: antithesis, tuning: .default),
                     "below the strict bar while the poles are opposed")

        var converged = DialecticalMemory(historyWindow: 8, tensionCeiling: 0.35)
        converged.recordHeard(text: "bridge", embedding: bridge, turnIndex: 0)
        for _ in 0..<DialecticalDynamics.Tuning.default.synthesisSustainK {
            converged.observe(tension: 0.1)   // a run of low-tension turns
        }
        XCTAssertNotNil(converged.synthesisCandidate(thesis: thesis, antithesis: antithesis, tuning: .default),
                        "sustained convergence lowers the bar and admits the synthesis")
    }
}
