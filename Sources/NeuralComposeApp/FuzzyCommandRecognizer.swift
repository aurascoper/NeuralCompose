import Foundation
import BCICore

/// ASR-tolerant command recognizer: matches transcripts against the
/// vocabulary by token-level edit-distance similarity instead of
/// `StubCommandRecognizer`'s exact/prefix match, so minor speech-to-text
/// noise ("phase bee debug" for "phase b debug") still resolves.
///
/// **Match heuristic:**
///
///   1. Clean the input the same way `StubCommandRecognizer` does
///      (lowercase, trim, strip outer punctuation, strip politeness
///      prefixes/suffixes — see `CommandTextNormalizer`), then split
///      into tokens, collapsing single-letter ASR spellings ("bee" ->
///      "b") to the bare letter.
///   2. For every alias of every descriptor, compute a Dice-like
///      token-overlap coefficient: each alias token is greedily paired
///      with its best still-unused input token via Levenshtein
///      similarity, and the score is
///      `2 * matchedTokenPairs / (aliasTokenCount + inputTokenCount)`.
///      Both a missing alias word and a spurious extra input word cost
///      points, so a phrase has to actually resemble the *whole*
///      alias, not just contain one matching word.
///   3. Each descriptor's best-scoring alias becomes its candidate
///      score. The best candidate overall must clear `acceptThreshold`
///      to be considered a match at all — otherwise the transcript is
///      judged unrelated to any command ("open the debug thing").
///   4. **Input-coverage guard.** The winning alias must also account
///      for most of what the user actually said (`minInputCoverage`).
///      Without this, "I want to start recording a podcast" would
///      fuzzy-match `.startRecording` — the alias "start recording" is
///      a good partial overlap, but "a podcast" is unexplained
///      leftover content, and the Dice score alone doesn't penalize
///      that enough when the alias is short relative to the input.
///      This mirrors `StubCommandRecognizer`'s prefix rule, which
///      exists for exactly the same reason (see that type's doc
///      comment on "the podcast case") — a real LLM-based recognizer
///      would understand the qualifier; this one stays conservative.
///   5. **Ambiguity rejection.** If the runner-up candidate belongs to
///      a *different* command and scores within `ambiguityMargin` of
///      the winner, the recognizer refuses to guess and returns `nil`
///      rather than picking arbitrarily. ("record" alone is
///      equally close to "start recording" and "stop recording" —
///      the shared word "recording" — with nothing to disambiguate
///      which one the user meant.)
///
/// Deliberately conservative in scope: no embeddings, no learned
/// confidence, no context from prior turns. Those are later layers;
/// this one only widens what counts as "the same phrase, roughly."
public struct FuzzyCommandRecognizer: AppCommandRecognizing {

    public init() {}

    public func recognize(
        _ text: String,
        in descriptors: [CommandDescriptor]
    ) -> AppCommand? {
        let cleaned = CommandTextNormalizer.clean(text)
        guard !cleaned.isEmpty else { return nil }
        let inputTokens = CommandTextNormalizer.tokens(cleaned)
        guard !inputTokens.isEmpty else { return nil }

        var scored: [(command: AppCommand, score: Double, coverage: Double)] = []
        for descriptor in descriptors {
            var best = (score: 0.0, coverage: 0.0)
            for alias in descriptor.aliases {
                let aliasTokens = alias.lowercased().split(separator: " ").map(String.init)
                let candidate = Self.tokenSetSimilarity(input: inputTokens, alias: aliasTokens)
                if candidate.score > best.score {
                    best = candidate
                }
            }
            scored.append((descriptor.command, best.score, best.coverage))
        }
        scored.sort { $0.score > $1.score }

        guard let top = scored.first,
              top.score >= Self.acceptThreshold,
              top.coverage >= Self.minInputCoverage
        else { return nil }

        if let runnerUp = scored.dropFirst().first(where: { $0.command != top.command }),
           top.score - runnerUp.score < Self.ambiguityMargin {
            return nil
        }

        return top.command
    }

    // MARK: - Scoring

    /// An alias token and an input token are considered the same word
    /// only if their edit-distance similarity clears this bar. Below
    /// it, the words are treated as unrelated rather than a fuzzy
    /// variant of each other.
    ///
    /// Set above the naive-looking `0.5` on purpose: at `0.5`,
    /// "dictation" and "calibration" satisfy the bar (similarity
    /// `0.545`) purely because they're both ~10-letter words sharing
    /// the common `-ation` suffix — an orthographic coincidence with
    /// no relation to what was actually said. That false match tied
    /// `.startDictation` against `.beginCalibration`'s real match for
    /// "begin calibration" and made the recognizer reject it as
    /// ambiguous. `0.6` clears that specific collision while still
    /// keeping the matches the recognizer actually relies on, e.g.
    /// "record" ~ "recording" at `0.667` (see the ambiguity-rejection
    /// test for "record" alone).
    private static let tokenMatchThreshold = 0.6

    /// The best candidate's token-overlap score must clear this bar
    /// to be considered a match at all. Tuned against the recognizer's
    /// own regression suite (`FuzzyCommandRecognizerTests`): high
    /// enough to reject "open the debug thing" against
    /// `.openPhaseBDebug`'s aliases (~0.6), low enough to accept
    /// "phase bee debug" against them (~0.86).
    private static let acceptThreshold = 0.63

    /// Fraction of *input* tokens the winning alias must account for.
    /// Rejects "start recording a podcast" (only "start"/"recording"
    /// explained, 2 of 4 input tokens = 0.5 coverage) while still
    /// accepting "phase bee debug" (all 3 input tokens explained by
    /// "open phase b debug" = 1.0 coverage).
    private static let minInputCoverage = 0.6

    /// If the runner-up candidate (for a *different* command) scores
    /// within this margin of the winner, the match is ambiguous and
    /// the recognizer returns `nil` instead of guessing.
    private static let ambiguityMargin = 0.05

    /// Dice-like coefficient over greedily-paired tokens, plus the
    /// fraction of `input` tokens that were part of a matched pair
    /// (`coverage`). See the type doc comment, steps 2 and 4, for the
    /// full explanation of each.
    private static func tokenSetSimilarity(
        input: [String], alias: [String]
    ) -> (score: Double, coverage: Double) {
        guard !input.isEmpty, !alias.isEmpty else { return (0, 0) }
        var usedInput = Set<Int>()
        var matched = 0
        for aliasToken in alias {
            var bestIndex: Int?
            var bestScore = 0.0
            for (index, inputToken) in input.enumerated() where !usedInput.contains(index) {
                let score = Levenshtein.similarity(aliasToken, inputToken)
                if score > bestScore {
                    bestScore = score
                    bestIndex = index
                }
            }
            if bestScore >= tokenMatchThreshold, let bestIndex {
                usedInput.insert(bestIndex)
                matched += 1
            }
        }
        let score = 2.0 * Double(matched) / Double(alias.count + input.count)
        let coverage = Double(matched) / Double(input.count)
        return (score, coverage)
    }
}
