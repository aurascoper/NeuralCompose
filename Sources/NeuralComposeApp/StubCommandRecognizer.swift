import Foundation
import BCICore

/// Deterministic command recognizer with no external dependencies.
///
/// Match heuristic (intentionally conservative — a real LLM-based
/// recognizer would handle the cases this rejects):
///
///   1. Lowercase input, trim whitespace, strip leading/trailing punctuation.
///   2. Strip common politeness prefixes: "please ", "i want to ",
///      "i'd like to ", "can you ", "could you ", "i need to ".
///   3. Strip common politeness suffixes: " please", " thanks", " thank you".
///   4. For each descriptor, check if the cleaned input is a prefix of
///      any of its aliases. If multiple aliases across descriptors
///      match, prefer the longest alias match (most specific).
///   5. If no alias match, return nil.
///
/// **Why "input is a prefix of alias" rather than the reverse.**
/// "I want to start recording a podcast" must NOT trigger
/// `.startRecording` — the user is talking about *a podcast recording*,
/// not the in-app recorder. The prefix-of-alias rule rejects this:
/// the cleaned input "start recording a podcast" is longer than the
/// alias "start recording", so it isn't a prefix of any alias, and
/// the stub returns nil.
///
/// The same rule accepts: "open phase b" (exact match), "open the
/// phase b debug window" (input equals an alias verbatim), "could
/// you open phase b" (strip prefix → exact match), "reset please"
/// (strip suffix → exact match), "reset" (exact match against the
/// short alias), "calibrate" (exact match against the short alias).
public struct StubCommandRecognizer: AppCommandRecognizing {

    public init() {}

    public func recognize(
        _ text: String,
        in descriptors: [CommandDescriptor]
    ) -> AppCommand? {
        let cleaned = Self.clean(text)
        guard !cleaned.isEmpty else { return nil }

        var bestLength = 0
        var bestCommand: AppCommand? = nil

        for descriptor in descriptors {
            for alias in descriptor.aliases {
                let aliasLower = alias.lowercased()
                // Match: input is a prefix of alias, OR input equals alias.
                // Both forms accepted so "reset" and "reset composition"
                // both resolve to .resetComposition.
                let isMatch = (aliasLower.hasPrefix(cleaned) || aliasLower == cleaned)
                guard isMatch else { continue }
                // Prefer the longest matched alias (most specific).
                if aliasLower.count > bestLength {
                    bestLength = aliasLower.count
                    bestCommand = descriptor.command
                }
            }
        }

        return bestCommand
    }

    // MARK: - Cleaning

    /// Lowercase, trim, strip outer punctuation, strip politeness
    /// prefixes/suffixes. Returns the cleaned string, or empty if
    /// the input was empty/whitespace-only.
    static func clean(_ text: String) -> String {
        // Step 1: lowercase + trim + strip outer punctuation
        var s = text.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        s = s.trimmingCharacters(in: CharacterSet.punctuationCharacters)
        guard !s.isEmpty else { return "" }

        // Step 2: strip politeness prefixes (longest first so "i want to "
        // matches before "i ").
        for prefix in politenessPrefixes {
            if s.hasPrefix(prefix) {
                s = String(s.dropFirst(prefix.count))
                s = s.trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
        }

        // Step 3: strip politeness suffixes (longest first so
        // " thank you" matches before " thanks").
        for suffix in politenessSuffixes {
            if s.hasSuffix(suffix) {
                s = String(s.dropLast(suffix.count))
                s = s.trimmingCharacters(in: .whitespacesAndNewlines)
                break
            }
        }

        return s
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
}
