import XCTest
@testable import BCICore
@testable import BCILLM

/// Regression coverage for a real bug: `MLXNextWordPredictor.generate` used
/// to drift into short-period decoding loops instead of stopping cleanly (no
/// repetition penalty, no chat-turn framing for an instruct model). Two real
/// manual reproductions exercised two different failure modes — a
/// continuation drift and a self-referential constraint violated via decode
/// loop — so both are regression-tested here, alongside cases that separate
/// two more failure classes this bug conflated: whether chat framing changes
/// *behavior* (follows an instruction rather than continuing/echoing it),
/// and whether decoder stability holds even when there's nothing to
/// misunderstand or echo (a plain sequence continuation).
///
/// The implementation intentionally lands all three correctness
/// improvements — chat templating, EOS registration, repetition penalty —
/// together (see `MLXNextWordPredictor.generate`); see
/// `docs/reviews/predictor-generation-fix-ablation.md` for the (human-run)
/// experiment understanding their relative contribution.
///
/// Follows the same hardware-optional idiom as
/// `PredictorFactoryCrashSafetyTests`: call `PredictorFactory.live()` and
/// only exercise the real assertions when it resolves to `.mlx` on the
/// machine running the test, rather than skipping.
final class MLXGenerationRegressionTests: XCTestCase {

    func testRefinementGenerationDoesNotDegenerateIntoRepetition() async throws {
        try await assertNoShortPeriodDecodingLoop(prompt: "Say the word no")
    }

    /// Repro #2: a self-referential constraint the model immediately
    /// violated via a period-2 "and a" decode loop in the original bug — a
    /// stronger signal than repro #1 alone, since this can't be read as
    /// "the model is just continuing the phrase."
    func testRefinementGenerationHonorsStatedConstraintUnderRepetitionPressure() async throws {
        try await assertNoShortPeriodDecodingLoop(
            prompt: "I will not say the words \"a\" or \"and\" again in this or any future sentences transcribed"
        )
    }

    /// Repro #3: validates that chat-turn framing actually changes model
    /// *behavior* (follows a rewrite instruction), not just that the decoder
    /// avoids looping. A model that's merely continuing the prompt would
    /// echo or extend it; one that's in "assistant turn" mode should
    /// produce a distinct rewritten sentence instead.
    func testRefinementGenerationFollowsRewriteInstructionRatherThanContinuingIt() async throws {
        let resolved = await PredictorFactory.live()
        guard resolved.kind == .mlx else {
            _ = resolved.generator
            return
        }
        let prompt = "Rewrite this more politely: \"Close the window.\""
        let output = try await resolved.generator.generate(
            prompt: prompt, maxTokens: 120, temperature: 0.7, cancellationID: UUID()
        )
        XCTAssertFalse(
            output.lowercased().hasPrefix(prompt.lowercased()),
            "output looks like a continuation of the prompt rather than a rewrite: \(output)"
        )
        Self.assertWellFormedGeneration(output)
    }

    /// A different decoder-failure class than the "more politely" case
    /// above: a longer, more syntactically complex source sentence with a
    /// subordinate clause ("although..."), which is more likely to tempt a
    /// small model into echoing structure back instead of compressing it.
    func testRefinementGenerationRewritesOpenEndedSentenceWithoutLoopingOrEchoing() async throws {
        let resolved = await PredictorFactory.live()
        guard resolved.kind == .mlx else {
            _ = resolved.generator
            return
        }
        let prompt = """
            Rewrite this sentence in a clearer way:

            The experiment was successful although several calibration steps were required.
            """
        let output = try await resolved.generator.generate(
            prompt: prompt, maxTokens: 120, temperature: 0.7, cancellationID: UUID()
        )
        XCTAssertFalse(
            output.lowercased().hasPrefix(prompt.lowercased()),
            "output looks like a continuation of the prompt rather than a rewrite: \(output)"
        )
        Self.assertWellFormedGeneration(output)
    }

    /// Isolates decoder stability from instruction-following: repros #1-2
    /// conflate the two (there's an instruction to misunderstand and
    /// content to echo). A plain sequence continuation requires almost no
    /// reasoning, so if this one ever fails, the failure is attributable to
    /// decoder dynamics specifically — the clean signal you'd want when
    /// comparing this backend against a second one (Gemma, Phi, ...) later.
    func testRefinementGenerationContinuesSimpleSequenceWithoutDecodingLoop() async throws {
        let resolved = await PredictorFactory.live()
        guard resolved.kind == .mlx else {
            _ = resolved.generator
            return
        }
        let prompt = "Continue the sequence:\n1\n2\n3\n4"
        let output = try await resolved.generator.generate(
            prompt: prompt, maxTokens: 120, temperature: 0.7, cancellationID: UUID()
        )
        Self.assertWellFormedGeneration(output)
    }

    /// Pure-logic coverage for the detector itself, independent of MLX
    /// hardware — the tests above only exercise it when real weights are
    /// present, but the detector's threshold calibration (see its doc
    /// comment) is exactly the kind of thing that can silently regress
    /// without anyone noticing on a machine without the model. Both real
    /// bug transcripts are included verbatim.
    func testHasShortPeriodDecodingLoopDetectorAgainstKnownCases() {
        let cases: [(text: String, expectLoop: Bool)] = [
            ("Say the word no more and a and a", true),
            (
                "I will not say the words \"a\" or \"and\" again in this or any future "
                    + "sentences transcribed and a and a",
                true
            ),
            ("and and and and", true),
            ("and and and", false),
            ("of the of the of the", true),
            ("of the of the", true),
            ("a b a c a b", false),
            ("A more polite version of your request would be: could you please close the window?", false),
            ("please close the window", false),
            ("the cat sat on the mat and looked at the door", false),
            ("no no thanks", false),
        ]
        for (text, expectLoop) in cases {
            XCTAssertEqual(
                Self.hasShortPeriodDecodingLoop(text), expectLoop,
                "unexpected result for: \(text)"
            )
        }
    }

    private func assertNoShortPeriodDecodingLoop(prompt: String) async throws {
        let resolved = await PredictorFactory.live()
        guard resolved.kind == .mlx else {
            // No real weights on this machine — nothing to regress-test.
            _ = resolved.generator
            return
        }
        let output = try await resolved.generator.generate(
            prompt: prompt,
            maxTokens: 120, temperature: 0.7, cancellationID: UUID()
        )
        Self.assertWellFormedGeneration(output)
    }

    /// "Doesn't loop" and "eventually stops" are different regressions — a
    /// generation could avoid short-period decoding loops entirely and
    /// still ramble to `maxTokens` without ever concluding. Shared by every
    /// real-generation test above so both failure modes are always guarded
    /// together, with callers layering on their own prompt-specific checks
    /// (e.g. the rewrite tests' echo check) on top.
    private static func assertWellFormedGeneration(
        _ output: String, maxWords: Int = 80,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertFalse(output.isEmpty, file: file, line: line)
        XCTAssertFalse(
            Self.hasShortPeriodDecodingLoop(output),
            "generation degenerated into a short-period decoding loop: \(output)",
            file: file, line: line
        )
        XCTAssertLessThan(
            output.split(separator: " ").count, maxWords,
            "generation ran long without stopping cleanly: \(output)",
            file: file, line: line
        )
    }

    /// True if a short word n-gram (period 1-3 — single words, pairs, or
    /// triples) recurs immediately and mechanically — a specific decoder
    /// pathology, not "repetition" in general: the same failure shape
    /// whether the surface content is "and a and a" or "one two three one
    /// two three." Compares whole n-gram slices at each candidate start
    /// position rather than single elements at a fixed lag — comparing
    /// only `words[i] == words[i - period]` doesn't verify the *whole*
    /// n-gram repeats and over/under-counts depending on period.
    ///
    /// The threshold is period-aware, not a flat 3: the actual observed bug
    /// ("...and a and a", a period-2 pair) only repeats **twice**, not three
    /// times — a flat `requiredRepeats = 3` would silently fail to flag the
    /// real regression case below. Requiring 2 full repeats for period 2/3
    /// (a 4-6 word repeated span) and 4 for period 1 (single words are more
    /// likely to repeat incidentally in natural language, e.g. "no no
    /// thanks") was verified against both real bug transcripts plus several
    /// clean (non-repetitive) sentences before landing here.
    private static func hasShortPeriodDecodingLoop(_ text: String) -> Bool {
        let words = text.lowercased().split(separator: " ").map(String.init)
        for period in 1...3 {
            let requiredRepeats = period == 1 ? 4 : 2
            guard words.count >= period * requiredRepeats else { continue }
            var start = 0
            while start + period * 2 <= words.count {
                let candidate = Array(words[start..<(start + period)])
                var repeatCount = 1
                var next = start + period
                while next + period <= words.count,
                      Array(words[next..<(next + period)]) == candidate {
                    repeatCount += 1
                    next += period
                }
                if repeatCount >= requiredRepeats { return true }
                start += 1
            }
        }
        return false
    }
}
