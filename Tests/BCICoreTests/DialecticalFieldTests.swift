import XCTest
import Foundation
@testable import BCICore

/// Milestone 5 — the two clocks. The fast gloss EMA tracks the EEG window; the
/// slow weight field has inertia, so a one-window spike can't swing the
/// dialogue's semantic identity. The `target` policy's *direction* is asserted
/// (relaxed → novelty, engaged → coherence) without pinning its exact magnitude.
final class DialecticalFieldTests: XCTestCase {

    // MARK: - SpectralGloss (fast clock)

    func testGlossScalarRelaxedIsHighEngagedIsLowNeutralIsMid() {
        XCTAssertGreaterThan(SpectralGloss.scalar(for: .drowsyFatigued), 0.9)
        XCTAssertGreaterThan(SpectralGloss.scalar(for: .relaxedWakefulness), 0.6)
        XCTAssertEqual(SpectralGloss.scalar(for: .neutralBaseline), 0.5)
        XCTAssertEqual(SpectralGloss.scalar(for: nil), 0.5, "no estimate ⇒ neutral, unbiased")
        XCTAssertLessThan(SpectralGloss.scalar(for: .engagedFocused), 0.4)
        XCTAssertLessThan(SpectralGloss.scalar(for: .highCognitiveLoad), 0.3)
    }

    func testGlossEMAMovesTowardButNotAllTheWay() {
        var g = SpectralGloss(value: 0.5)
        g.update(.drowsyFatigued, alpha: 0.6)   // target 1.0
        XCTAssertEqual(g.value, 0.5 + 0.6 * 0.5, accuracy: 1e-5, "EMA eases toward the target")
    }

    // MARK: - DialecticalField (slow clock)

    func testFieldStartsUnbiasedAtBase() {
        let f = DialecticalField(base: .balanced, inertia: 0.12, wind: 0.35)
        XCTAssertEqual(f.weights, .balanced, "first turn is unbiased")
    }

    func testSustainedRelaxationShiftsTowardNovelty() {
        var f = DialecticalField(base: .balanced, inertia: 0.2, wind: 0.35)
        let n0 = f.weights.novelty
        for _ in 0..<30 { f.advance(glossScalar: 1.0, entropy: 0, drift: 0) }  // sustained relaxed
        XCTAssertGreaterThan(f.weights.novelty, n0, "a relaxed gloss gently raises novelty")
        XCTAssertLessThan(f.weights.coherence, DialecticalWeights.balanced.coherence,
                          "…while lowering coherence")
    }

    func testSustainedEngagementShiftsTowardCoherence() {
        var f = DialecticalField(base: .balanced, inertia: 0.2, wind: 0.35)
        for _ in 0..<30 { f.advance(glossScalar: 0.0, entropy: 0, drift: 0) }  // sustained engaged
        XCTAssertLessThan(f.weights.novelty, DialecticalWeights.balanced.novelty,
                          "an engaged gloss lowers novelty")
        XCTAssertGreaterThan(f.weights.coherence, DialecticalWeights.balanced.coherence,
                             "…and raises coherence")
    }

    func testHighEntropyReinsInNovelty() {
        // Same relaxed gloss, but a wandering dialogue should end lower on novelty.
        var calm = DialecticalField(base: .balanced, inertia: 0.2, wind: 0.35)
        var wandering = DialecticalField(base: .balanced, inertia: 0.2, wind: 0.35)
        for _ in 0..<30 {
            calm.advance(glossScalar: 1.0, entropy: 0.0, drift: 0.0)
            wandering.advance(glossScalar: 1.0, entropy: 0.9, drift: 0.9)
        }
        XCTAssertLessThan(wandering.weights.novelty, calm.weights.novelty,
                          "high entropy/drift damp the novelty the gloss would otherwise add")
    }

    func testOneWindowSpikeBarelyMovesTheWeights_TwoClockSeparation() {
        // The fast gloss reacts to a single spike, but the slow field absorbs it.
        var f = DialecticalField(base: .balanced, inertia: 0.12, wind: 0.35)
        let before = f.weights.novelty
        f.advance(glossScalar: 1.0, entropy: 0, drift: 0)   // a single relaxed window
        let delta = abs(f.weights.novelty - before)
        // Full target shift would be wind (0.35); inertia 0.12 must keep the
        // single-step move well under a third of that.
        XCTAssertLessThan(delta, 0.35 * 0.12 + 1e-4, "one window can't swing the semantic identity")
    }
}
