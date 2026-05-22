import Foundation
import BCICore

/// A small, deterministic next-word predictor that always works, even without
/// MLX, without model weights, and without network.
///
/// Strategy:
///   • If `context` ends mid-word (no trailing space), suggest 3 plausible
///     completions from a tiny built-in unigram table.
///   • If `context` ends on a sentence/clause boundary, suggest common
///     sentence starters.
///   • Otherwise, suggest the highest-frequency continuations conditioned on
///     the trailing bigram, falling back to unigrams.
///
/// Quality is intentionally modest — this is a stand-in so the app demos
/// end-to-end without a model. Switch on real MLX for actual fluency.
public final class StubNextWordPredictor: NextWordPredicting, @unchecked Sendable {

    public let isLive: Bool = false
    public let modelIdentifier: String = "stub-unigram"

    public init() {}

    public func predictNextWords(
        context: String,
        maxCandidates: Int,
        temperature: Double,
        cancellationID: UUID
    ) async throws -> [PredictedWord] {
        try Task.checkCancellation()

        let suggestions = candidates(for: context, count: maxCandidates)
        return suggestions.map {
            PredictedWord(text: " " + $0.text, probability: $0.prob)
        }
    }

    // MARK: - Tables

    private static let starters: [(text: String, prob: Float)] = [
        ("I",      0.30),
        ("The",    0.22),
        ("Yes",    0.10),
        ("No",     0.08),
        ("Hello",  0.08),
        ("Please", 0.06),
        ("Help",   0.06),
        ("Thank",  0.05),
        ("Water",  0.05),
    ]

    private static let unigrams: [(text: String, prob: Float)] = [
        ("the",    0.10), ("and",   0.08), ("a",      0.07), ("to",  0.06),
        ("of",     0.06), ("is",    0.05), ("in",     0.05), ("you", 0.05),
        ("not",    0.04), ("for",   0.04), ("on",     0.03), ("with",0.03),
        ("water",  0.02), ("food",  0.02), ("help",   0.02), ("yes", 0.02),
        ("no",     0.02), ("please",0.02), ("thank",  0.02), ("tired",0.02),
    ]

    private static let bigramFollows: [String: [(text: String, prob: Float)]] = [
        "i":     [("am", 0.22), ("need", 0.18), ("want", 0.12), ("feel", 0.10), ("would", 0.08)],
        "i am":  [("tired", 0.20), ("hungry", 0.18), ("fine", 0.14), ("ready", 0.12), ("happy", 0.10)],
        "the":   [("water", 0.18), ("food", 0.16), ("door", 0.12), ("light", 0.10), ("room", 0.08)],
        "thank": [("you", 0.92)],
        "please":[("help", 0.30), ("come", 0.20), ("wait", 0.12), ("stop", 0.10)],
        "yes":   [("please", 0.40), ("thank", 0.20), ("I", 0.20)],
        "no":    [("thanks", 0.30), ("not", 0.20), ("more", 0.15)],
    ]

    private func candidates(for context: String, count: Int) -> [(text: String, prob: Float)] {
        let trimmed = context.trimmingCharacters(in: .whitespacesAndNewlines)

        // Empty context or starts of sentence → starters.
        if trimmed.isEmpty || trimmed.hasSuffix(".") || trimmed.hasSuffix("?") || trimmed.hasSuffix("!") {
            return Array(Self.starters.prefix(count))
        }

        // Pick the last 1–2 tokens and look in the bigram table.
        let tokens = trimmed
            .split(whereSeparator: { $0.isWhitespace })
            .map { String($0).lowercased() }

        if let last2 = tokens.suffix(2).joined(separator: " ").nonEmpty,
           let hits = Self.bigramFollows[last2], !hits.isEmpty {
            return Array(hits.prefix(count))
        }
        if let last1 = tokens.last,
           let hits = Self.bigramFollows[last1], !hits.isEmpty {
            return Array(hits.prefix(count))
        }
        return Array(Self.unigrams.prefix(count))
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
