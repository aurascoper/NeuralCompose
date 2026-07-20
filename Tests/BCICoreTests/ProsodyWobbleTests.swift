import XCTest
@testable import BCICore

/// Stage 2 de-robotify — the confidence-*wobble*. Dialectic node 35: "a voice
/// reads as robotic when every claim lands at the same confidence." These pin
/// that the planner actually varies commitment per phrase (and never leaves the
/// AVSpeech-valid ranges), so the wobble can't silently regress to a flat cadence.
final class ProsodyWobbleTests: XCTestCase {

    func testCommitmentIsNegativeForHedgesPositiveForIntensifiers() {
        XCTAssertLessThan(ProsodyWobble.commitment(of: "Maybe this could possibly work."), 0)
        XCTAssertGreaterThan(ProsodyWobble.commitment(of: "This must clearly work."), 0)
    }

    func testQuestionLowersCommitment() {
        XCTAssertLessThan(ProsodyWobble.commitment(of: "Does it work?"),
                          ProsodyWobble.commitment(of: "It works."))
    }

    func testNeutralPhraseHasZeroCommitment() {
        XCTAssertEqual(ProsodyWobble.commitment(of: "The cat sat on the mat."), 0, accuracy: 0.0001)
    }

    /// The core wobble: a hedged clause is spoken slower, softer, and higher
    /// (rising = uncertain); a committed one quicker, fuller, lower (falling =
    /// conviction). Selected by commitment sign so the assertion is independent
    /// of chunk ordering.
    func testHedgedPhraseSofterSlowerHigherThanCommitted() {
        let plan = ProsodyWobble.plan("This must clearly work. Maybe it could possibly fail.")
        guard let certain = plan.first(where: { ProsodyWobble.commitment(of: $0.phrase) > 0 })?.prosody,
              let hedged  = plan.first(where: { ProsodyWobble.commitment(of: $0.phrase) < 0 })?.prosody else {
            return XCTFail("expected one committed and one hedged phrase, got \(plan.map(\.phrase))")
        }
        XCTAssertLessThan(hedged.rate ?? 0, certain.rate ?? 0, "hedged should be slower")
        XCTAssertLessThan(hedged.volume ?? 0, certain.volume ?? 0, "hedged should be softer")
        XCTAssertGreaterThan(hedged.pitchMultiplier ?? 0, certain.pitchMultiplier ?? 0, "hedged should rise")
    }

    func testProsodyStaysInAVSpeechValidRanges() {
        for text in ["maybe perhaps possibly unsure could might probably seems",
                     "must clearly always never definitely certainly absolutely obviously"] {
            for (_, p) in ProsodyWobble.plan(text) {
                XCTAssert((0.30 ... 0.60).contains(p.rate ?? 0.5), "rate \(p.rate ?? -1)")
                XCTAssert((0.85 ... 1.15).contains(p.pitchMultiplier ?? 1.0), "pitch \(p.pitchMultiplier ?? -1)")
                XCTAssert((0.60 ... 1.00).contains(p.volume ?? 0.9), "volume \(p.volume ?? -1)")
                XCTAssertGreaterThanOrEqual(p.preUtteranceDelay ?? 0, 0)
            }
        }
    }

    /// Even two neutral (commitment-0) sentences must not land identically — the
    /// per-index jitter is what keeps consecutive clauses off the same footing.
    func testJitterBreaksAdjacencyMonotonyOnNeutralPhrases() {
        let plan = ProsodyWobble.plan("The cat sat on the mat. The dog ran in the yard.")
        guard plan.count >= 2 else { return XCTFail("expected ≥2 phrases, got \(plan.count)") }
        XCTAssertNotEqual(plan[0].prosody.rate, plan[1].prosody.rate)
    }
}
