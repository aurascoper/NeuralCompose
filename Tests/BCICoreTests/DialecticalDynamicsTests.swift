import XCTest
@testable import BCICore

/// Milestone 1 — the pure competition engine. Every test is deterministic:
/// fixed embeddings and a fixed random draw, no I/O, no actors.
final class DialecticalDynamicsTests: XCTestCase {

    // MARK: - Fixtures

    /// Builds an L2-normalized `Embedding` from a raw vector (satisfies the
    /// `Embedding.values` invariant that `cosineSimilarity` relies on).
    private func emb(_ v: [Float], id: String = "test-v1") -> Embedding {
        let norm = sqrtf(v.reduce(0) { $0 + $1 * $1 })
        let unit = norm > 0 ? v.map { $0 / norm } : v
        return Embedding(values: unit, modelID: id, dimension: v.count, version: "1", seed: 0)
    }

    private func scored(potential: Float, roleID: String = "r",
                        energy: DialecticalEnergy = .init(coherence: 0.5, resonance: 0.5, novelty: 0.5),
                        text: String = "x") -> ScoredCandidate {
        ScoredCandidate(
            candidate: DialecticalCandidate(text: text, embedding: emb([1, 0]), roleID: roleID),
            energy: energy, potential: potential, roleFulfillment: 0.5
        )
    }

    // MARK: - Comparability

    /// Swift twin of the Rust port's `Some(0.0) != None` pin: orthogonal-and-
    /// comparable is `0`; incomparable is `nil`, never a score.
    func testIncomparableIsNilNotZero() throws {
        let a = emb([1, 0], id: "a"), orthogonal = emb([0, 1], id: "a")
        XCTAssertEqual(try XCTUnwrap(a.cosineSimilarity(to: orthogonal)), 0)
        XCTAssertNil(a.cosineSimilarity(to: emb([1, 0], id: "b")), "different modelID")
        XCTAssertNil(a.cosineSimilarity(to: emb([1, 0, 0], id: "a")), "different dimension")
        XCTAssertNil(DialecticalDynamics.centroid(of: [a, emb([1, 0], id: "b")]), "mixed spaces")
        XCTAssertNotNil(DialecticalDynamics.centroid(of: [a, orthogonal]))
    }

    // MARK: - Energy

    func testCoherenceIsHighWhenCandidateMatchesHeard() {
        let heard = emb([1, 0, 0])
        let e = DialecticalDynamics.energy(candidate: emb([1, 0, 0]), heard: heard,
                                           historyCentroid: nil, replyCentroid: nil)
        XCTAssertEqual(e.coherence, 1.0, accuracy: 1e-5, "identical to heard ⇒ max coherence")
    }

    func testMissingCentroidsScoreNeutralNotBiased() {
        let e = DialecticalDynamics.energy(candidate: emb([0, 1, 0]), heard: emb([1, 0, 0]),
                                           historyCentroid: nil, replyCentroid: nil)
        XCTAssertEqual(e.resonance, 0.5, "no history ⇒ neutral resonance, not 0 or 1")
        XCTAssertEqual(e.novelty, 0.5, "no prior replies ⇒ neutral novelty, not maxed")
    }

    func testNoveltyRisesWithDistanceFromReplyHistory() {
        let replies = emb([1, 0, 0])
        let near = DialecticalDynamics.energy(candidate: emb([1, 0, 0]), heard: emb([0, 1, 0]),
                                              historyCentroid: nil, replyCentroid: replies)
        let far = DialecticalDynamics.energy(candidate: emb([-1, 0, 0]), heard: emb([0, 1, 0]),
                                             historyCentroid: nil, replyCentroid: replies)
        XCTAssertLessThan(near.novelty, far.novelty, "farther from prior replies ⇒ more novel")
    }

    // MARK: - Tension

    func testTensionIsZeroForAgreementAndHighForOpposition() {
        XCTAssertEqual(DialecticalDynamics.tension(among: [emb([1, 0]), emb([1, 0])]), 0,
                       accuracy: 1e-5, "identical candidates ⇒ no tension")
        let opposed = DialecticalDynamics.tension(among: [emb([1, 0]), emb([-1, 0])])
        XCTAssertEqual(opposed, 1.0, accuracy: 1e-5, "antipodal candidates ⇒ max tension")
    }

    // MARK: - Selection temperature

    func testHigherTensionSharpensTheCompetition() {
        let t = DialecticalDynamics.Tuning.default
        let cool = DialecticalDynamics.selectionTemperature(tension: 0, tuning: t)
        let hot = DialecticalDynamics.selectionTemperature(tension: 1, tuning: t)
        XCTAssertGreaterThan(cool, hot, "more tension ⇒ lower τ ⇒ sharper competition")
        XCTAssertGreaterThanOrEqual(hot, t.tauMin, "τ is floored so the bifurcation never dies")
    }

    // MARK: - Sampling / bifurcation

    func testNearEquilibriumTheDrawTipsTheBasin() {
        // Two near-equal potentials: the injected perturbation decides.
        let a = scored(potential: 0.50, roleID: "a", text: "A")
        let b = scored(potential: 0.50, roleID: "b", text: "B")
        let low = DialecticalDynamics.compete(scored: [a, b], tension: 0.2, draw: 0.01)
        let high = DialecticalDynamics.compete(scored: [a, b], tension: 0.2, draw: 0.99)
        XCTAssertEqual(low.outcome, .spoke(a.candidate), "a low draw lands in the first basin")
        XCTAssertEqual(high.outcome, .spoke(b.candidate), "a high draw lands in the other basin")
        XCTAssertFalse(low.decisive, "a near-tie is not decided by the dynamics")
    }

    func testDecisiveGapResolvesRegardlessOfPerturbation() {
        // A commanding potential lead: the mid draw still lands on the leader.
        let a = scored(potential: 1.30, roleID: "a", text: "A")
        let b = scored(potential: 0.20, roleID: "b", text: "B")
        let res = DialecticalDynamics.compete(scored: [a, b], tension: 0.8, draw: 0.5)
        XCTAssertEqual(res.outcome, .spoke(a.candidate), "the dynamics, not the draw, decide")
        XCTAssertTrue(res.decisive, "a gap ≥ decisiveGap is flagged decisive")
    }

    // MARK: - Silence (metastability)

    func testHighTensionStalemateFallsSilent() {
        let a = scored(potential: 0.50, roleID: "a")
        let b = scored(potential: 0.51, roleID: "b")   // margin 0.01 < ε
        let res = DialecticalDynamics.compete(scored: [a, b], tension: 0.8, draw: 0.5)
        XCTAssertEqual(res.outcome, .silent, "opposed + undecided ⇒ hold the tension, say nothing")
    }

    func testLowTensionNearTieStillSpeaks() {
        let a = scored(potential: 0.50, roleID: "a", text: "A")
        let b = scored(potential: 0.51, roleID: "b", text: "B")   // same tiny margin…
        let res = DialecticalDynamics.compete(scored: [a, b], tension: 0.1, draw: 0.99)
        // …but low tension is near-agreement, which should resolve, not fall silent.
        if case .silent = res.outcome {
            XCTFail("a low-tension near-tie is agreement, not a stalemate — it must speak")
        }
    }

    // MARK: - Synthesis

    func testForcedSynthesisTakesPrecedence() {
        let a = scored(potential: 0.50, roleID: "a")
        let b = scored(potential: 0.51, roleID: "b")
        let third = DialecticalCandidate(text: "the reconciling image",
                                         embedding: emb([0, 0, 1]), roleID: "synthesis")
        let res = DialecticalDynamics.compete(scored: [a, b], tension: 0.9, draw: 0.5,
                                              synthesis: third, forceSynthesis: true)
        XCTAssertEqual(res.outcome, .synthesized(third),
                       "a supplied synthesis resolves even a would-be silent stalemate")
    }

    func testSynthesisScoreRewardsReconciliationOverPoleCopy() {
        let thesis = emb([1, 0, 0])
        let antithesis = emb([0, 1, 0])
        // A candidate close to BOTH poles reconciles them; a copy of one pole
        // reaches only the poles' own cross-similarity baseline.
        let bridge = emb([0.4, 0.4, 0.9])
        let copyOfThesis = emb([1, 0, 0])

        let bridgeScore = DialecticalDynamics.synthesisScore(candidate: bridge,
                                                             thesis: thesis, antithesis: antithesis)
        let copyScore = DialecticalDynamics.synthesisScore(candidate: copyOfThesis,
                                                           thesis: thesis, antithesis: antithesis)
        XCTAssertGreaterThan(bridgeScore, copyScore,
                             "an idea close to both poles out-scores a copy of one")
        // A copy is close to thesis (1.0) but only baseline-close to antithesis;
        // its score is that weaker link — the orthogonal poles' baseline (0.5).
        XCTAssertEqual(copyScore, 0.5, accuracy: 1e-5,
                       "a pole copy scores only min(sim) = the cross-pole baseline")
    }
}
