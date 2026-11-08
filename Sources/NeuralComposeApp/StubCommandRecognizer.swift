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
///      any of its aliases. An input that EQUALS an alias wins outright;
///      otherwise, if multiple aliases across descriptors match as
///      prefixes, prefer the longest alias match (most specific).
///   5. If no alias match, return nil.
///
/// **Why an exact match beats a longer prefix match.** "say" is itself a
/// `.speak` alias and also the first word of the `.repeatLastUtterance`
/// aliases "say again" / "say that again". The user who said exactly "say"
/// meant the alias they said; the longest-prefix rule exists to pick the
/// most specific reading of a TRUNCATED phrase, and an exact alias is not
/// truncated. Within one command the two rules agree ("reset" is both an
/// alias and a prefix of "reset composition"), so this only matters where
/// a short alias of one command prefixes a longer alias of another.
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
        let cleaned = CommandTextNormalizer.clean(text)
        guard !cleaned.isEmpty else { return nil }

        var bestLength = 0
        var bestCommand: AppCommand? = nil

        for descriptor in descriptors {
            for alias in descriptor.aliases {
                let aliasLower = alias.lowercased()
                // An exact alias is the user's whole phrase: return it at
                // once, before any longer alias it happens to prefix.
                if aliasLower == cleaned { return descriptor.command }
                // Otherwise match when the input is a prefix of the alias
                // ("reset" for "reset composition"), preferring the
                // longest matched alias (most specific).
                guard aliasLower.hasPrefix(cleaned) else { continue }
                if aliasLower.count > bestLength {
                    bestLength = aliasLower.count
                    bestCommand = descriptor.command
                }
            }
        }

        return bestCommand
    }
}
