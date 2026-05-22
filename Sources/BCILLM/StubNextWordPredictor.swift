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

        // Break the "the X" → unigrams → "the" loop: every common object the
        // determiner emits gets at least one continuation that ends the clause
        // or pivots away from determiners.
        "water": [("please", 0.30), ("now", 0.22), ("here", 0.16), ("there", 0.12), ("soon", 0.10)],
        "food":  [("please", 0.30), ("now", 0.22), ("here", 0.16), ("ready", 0.12), ("soon", 0.10)],
        "door":  [("please", 0.30), ("now", 0.22), ("open", 0.18), ("closed", 0.12)],
        "light": [("please", 0.30), ("off", 0.24), ("on", 0.22), ("now", 0.12)],
        "room":  [("please", 0.30), ("now", 0.18), ("here", 0.14), ("quiet", 0.12)],
        "the water": [("please", 0.34), ("now", 0.24), ("is", 0.16), ("here", 0.14)],
        "the food":  [("please", 0.34), ("now", 0.24), ("is", 0.16), ("ready", 0.14)],
        "the door":  [("please", 0.34), ("open", 0.22), ("closed", 0.18), ("now", 0.14)],
        "the light": [("off", 0.34), ("on", 0.28), ("please", 0.18), ("now", 0.10)],
        "the room":  [("please", 0.30), ("is", 0.22), ("now", 0.16), ("quiet", 0.12)],

        // Closers — when the carousel surfaces these and the user commits one,
        // the trailing-punctuation branch in `candidates(for:)` triggers starters
        // on the next call, restarting the sentence cleanly.
        "now":   [(".", 0.40), ("please", 0.22), ("thank", 0.14)],
        "soon":  [(".", 0.50), ("please", 0.20)],
        "here":  [(".", 0.40), ("please", 0.22)],
        "there": [(".", 0.40), ("please", 0.22)],
        "off":   [(".", 0.50), ("now", 0.18)],
        "on":    [(".", 0.40), ("please", 0.18)],
        "open":  [(".", 0.45), ("please", 0.22)],
        "closed":[(".", 0.45), ("now", 0.18)],
        "ready": [(".", 0.50), ("now", 0.18)],
        "quiet": [(".", 0.50), ("please", 0.18)],
        "help":  [("please", 0.40), ("me", 0.30), (".", 0.18)],
        "tired": [(".", 0.55), ("now", 0.18)],
        "hungry":[(".", 0.55), ("please", 0.18)],
        "fine":  [(".", 0.55), (",", 0.15)],
        "happy": [(".", 0.55), (",", 0.15)],
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
