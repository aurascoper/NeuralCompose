import Foundation

/// Shared text-cleaning logic for command recognizers: lowercase,
/// trim, strip outer punctuation, strip politeness prefixes/suffixes.
/// Factored out of `StubCommandRecognizer` so `FuzzyCommandRecognizer`
/// doesn't duplicate the same heuristic.
enum CommandTextNormalizer {

    /// Lowercase, trim, strip outer punctuation, strip politeness
    /// prefixes/suffixes. Returns the cleaned string, or empty if
    /// the input was empty/whitespace-only.
    static func clean(_ text: String) -> String {
        var s = text.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        s = s.trimmingCharacters(in: CharacterSet.punctuationCharacters)
        guard !s.isEmpty else { return "" }

        for prefix in politenessPrefixes {
            if s.hasPrefix(prefix) {
                s = String(s.dropFirst(prefix.count))
                s = s.trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
        }

        for suffix in politenessSuffixes {
            if s.hasSuffix(suffix) {
                s = String(s.dropLast(suffix.count))
                s = s.trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
        }

        return s
    }

    /// Splits cleaned text into whitespace-separated tokens, with
    /// single-letter ASR phonetic spellings ("bee", "sea", "aitch", ...)
    /// collapsed to the bare letter they stand for. Speech recognizers
    /// commonly transcribe a spoken single letter — as in "Phase B" —
    /// as its full phonetic name rather than the letter itself, and
    /// this app's own vocabulary (`.openPhaseBDebug`'s "b") relies on
    /// exact-letter aliases. Only whole tokens are substituted, so
    /// ordinary words are never touched by accident.
    static func tokens(_ cleaned: String) -> [String] {
        cleaned
            .split(separator: " ")
            .map { letterHomophones[String($0)] ?? String($0) }
    }

    /// Order matters: longest prefixes first, so the most-specific
    /// prefix is tried before any shorter one is tried.
    private static let politenessPrefixes: [String] = [
        "i'd like to ",
        "i would like to ",
        "i want to ",
        "i need to ",
        "could you ",
        "can you ",
        "would you ",
        "please ",
    ]

    /// Order matters: longest suffixes first.
    private static let politenessSuffixes: [String] = [
        " thank you",
        " thanks",
        " please",
    ]

    /// Standard English phonetic spellings for letters, restricted to
    /// the ones that matter for single-letter tokens: no entries for
    /// words ("are", "eye", "why", "oh") that are common enough in
    /// ordinary speech to cause false positives outside this closed
    /// command vocabulary.
    private static let letterHomophones: [String: String] = [
        "bee": "b",
        "cee": "c",
        "dee": "d",
        "gee": "g",
        "aitch": "h",
        "jay": "j",
        "kay": "k",
        "pea": "p",
        "cue": "q",
        "ess": "s",
        "tee": "t",
        "vee": "v",
        "zee": "z",
        "zed": "z",
    ]
}
