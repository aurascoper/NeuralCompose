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
public final class StubNextWordPredictor: NextWordPredicting, TokenEmbeddingProviding, TextGenerating, @unchecked Sendable {

    public let isLive: Bool = false
    public let modelIdentifier: String = "stub-unigram"

    /// Dimensionality of the stub's fabricated embedding. Arbitrary — this
    /// vector has no semantic meaning, it just needs to exist and be stable
    /// so downstream PCA/visualization code has something to run against in
    /// synthetic mode without special-casing "no real predictor."
    private static let stubEmbeddingDimension = 16

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

    /// A deterministic, non-semantic stand-in vector derived from `text`'s
    /// content via FNV-1a (not `String.hashValue`, which is randomized per
    /// process and would make this non-reproducible). Exists purely so the
    /// 3D workspace visualizer has stable input in stub/synthetic mode; it
    /// carries no linguistic meaning the way `MLXNextWordPredictor`'s
    /// logit-vector embedding does.
    public func embedding(for text: String) async throws -> [Float] {
        var hash: UInt64 = 0xcbf29ce484222325 // FNV offset basis
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3 // FNV prime
        }
        var generator = SplitMix64(seed: hash)
        return (0..<Self.stubEmbeddingDimension).map { _ in
            Float(generator.next() % 2000) / 1000.0 - 1.0 // uniform in [-1, 1)
        }
    }

    // MARK: - TextGenerating

    /// Deterministic canned transform — no real generation in stub mode.
    /// Exists so the Refine UI is exercisable end-to-end in stub/synthetic
    /// mode without pretending to be a real dialectic pass; the "[stub-
    /// refined]" prefix makes it unmistakable this isn't real model output.
    public func generate(
        prompt: String,
        maxTokens: Int,
        temperature: Double,
        cancellationID: UUID
    ) async throws -> String {
        try Task.checkCancellation()
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return "[stub-refined] " + trimmed.prefix(80)
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

/// Minimal deterministic PRNG (SplitMix64) used only to expand a hash seed
/// into a sequence of values for the stub embedding. Not cryptographic.
private struct SplitMix64 {
    private var state: UInt64
    init(seed: UInt64) { self.state = seed }
    mutating func next() -> UInt64 {
        state = state &+ 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}
