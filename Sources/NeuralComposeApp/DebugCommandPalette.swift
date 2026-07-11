import Foundation
import SwiftUI
import BCICore

/// Pure-function filter that backs the debug command palette's search.
///
/// The palette itself is a SwiftUI view (not directly unit-testable
/// without an app context), so the search logic lives here as a
/// `static` function. The view's body just calls
/// `DebugCommandPalette.filter(descriptors, query:)` and renders the
/// result. Every ranking rule and edge case is testable in
/// `DebugCommandPaletteTests`.
///
/// **Ranking tiers, in priority order:**
///
///   1. **Title prefix** — query is a prefix of the descriptor's
///      `title` (case-insensitive). The single most specific
///      tier; the user's exact-prefix intent is the strongest
///      signal.
///   2. **Alias prefix** — query is a prefix of one of the
///      descriptor's `aliases` (case-insensitive). Most palette
///      searches land here.
///   3. **Title contains** — query appears anywhere in the
///      descriptor's `title` (case-insensitive).
///   4. **Alias contains** — query appears anywhere in one of the
///      descriptor's `aliases` (case-insensitive).
///
/// Within a tier, descriptors whose match starts at the leftmost
/// position in the haystack rank first (e.g. for tier 2 with
/// aliases "open phase b" and "open the phase b debug window"
/// and query "phase", "open phase b" wins because the match
/// starts at position 5 instead of 9). Ties break by the
/// descriptor's natural order in the input array — the palette
/// never reshuffles on a no-op query.
///
/// An empty query returns the input array in its original order —
/// no filtering, no ranking. This matches the user's mental model
/// ("empty box = everything available").
public enum DebugCommandPalette {

    /// Filters and ranks `descriptors` against `query`. Returns the
    /// full input array (in original order) when `query` is empty
    /// or whitespace-only. Returns an empty array when nothing
    /// matches.
    public static func filter(
        _ descriptors: [CommandDescriptor],
        query: String
    ) -> [CommandDescriptor] {
        let normalized = query
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalized.isEmpty else { return descriptors }

        // Score each descriptor. Lower score = higher rank.
        // Tiers: titlePrefix=0, aliasPrefix=1, titleContains=2, aliasContains=3.
        // Within a tier, smaller leftmost-match position ranks first.
        struct Scored {
            let descriptor: CommandDescriptor
            let tier: Int
            let position: Int
        }

        var scored: [Scored] = []
        for descriptor in descriptors {
            let titleLower = descriptor.title.lowercased()
            if let pos = prefixPosition(of: normalized, in: titleLower) {
                scored.append(Scored(descriptor: descriptor, tier: 0, position: pos))
                continue
            }
            if let (pos, _) = earliestAliasPrefix(
                of: normalized, in: descriptor.aliases
            ) {
                scored.append(Scored(descriptor: descriptor, tier: 1, position: pos))
                continue
            }
            if let pos = containsPosition(of: normalized, in: titleLower) {
                scored.append(Scored(descriptor: descriptor, tier: 2, position: pos))
                continue
            }
            if let (pos, _) = earliestAliasContains(
                of: normalized, in: descriptor.aliases
            ) {
                scored.append(Scored(descriptor: descriptor, tier: 3, position: pos))
                continue
            }
        }

        // Stable sort by (tier, position), preserving input order on
        // ties. Swift's `sorted` is not stable; we use `stableSorted`
        // semantics by sorting with the original index as a final
        // tiebreaker.
        let indexed = scored.enumerated().map { idx, s in
            (originalIndex: idx, score: s)
        }
        let ranked = indexed.sorted { lhs, rhs in
            if lhs.score.tier != rhs.score.tier {
                return lhs.score.tier < rhs.score.tier
            }
            if lhs.score.position != rhs.score.position {
                return lhs.score.position < rhs.score.position
            }
            return lhs.originalIndex < rhs.originalIndex
        }
        return ranked.map { $0.score.descriptor }
    }

    // MARK: - String match helpers

    /// Returns the leftmost position of `query` as a prefix of
    /// `haystack`, or nil if `query` is not a prefix. Position 0
    /// means the haystack starts with the query. Case-insensitive
    /// (callers pass already-lowercased strings).
    private static func prefixPosition(of query: String, in haystack: String) -> Int? {
        guard haystack.hasPrefix(query) else { return nil }
        return 0
    }

    /// Returns (leftmost prefix position, alias index) for the first
    /// alias where `query` is a prefix. Position 0 means the alias
    /// starts with the query. Or nil if no alias is a prefix.
    private static func earliestAliasPrefix(
        of query: String, in aliases: [String]
    ) -> (Int, Int)? {
        for (index, alias) in aliases.enumerated() {
            let aliasLower = alias.lowercased()
            if aliasLower.hasPrefix(query) {
                return (0, index)
            }
        }
        return nil
    }

    /// Returns the leftmost position of `query` as a substring of
    /// `haystack`, or nil if not present. Used for "contains" tier
    /// ranking.
    private static func containsPosition(of query: String, in haystack: String) -> Int? {
        // `range(of:)` is the right tool: returns the leftmost
        // occurrence's `Range<String.Index>`. Convert to an integer
        // offset for the rank comparator.
        guard let range = haystack.range(of: query) else { return nil }
        return haystack.distance(from: haystack.startIndex, to: range.lowerBound)
    }

    /// Returns (leftmost contains position, alias index) for the
    /// first alias that contains `query` as a substring. Or nil.
    private static func earliestAliasContains(
        of query: String, in aliases: [String]
    ) -> (Int, Int)? {
        for (index, alias) in aliases.enumerated() {
            let aliasLower = alias.lowercased()
            if let range = aliasLower.range(of: query) {
                let pos = aliasLower.distance(from: aliasLower.startIndex, to: range.lowerBound)
                return (pos, index)
            }
        }
        return nil
    }
}

// MARK: - SwiftUI view

/// ⌘⇧P command palette — the first new emitter for the AppCommand
/// surface. A `TextField` at the top, a `List` of completions below.
/// The view itself knows no strings: it consumes `[CommandDescriptor]`
/// from the dispatcher and applies `DebugCommandPalette.filter` to
/// produce the visible list. Selecting a row calls
/// `dispatcher.perform(.X)` and dismisses the overlay.
///
/// This is the architecture's proof point: a non-trivial emitter
/// that searches descriptors (the same vocabulary the stub recognizer
/// searches) and routes through the dispatcher. Once the palette
/// works in daily use, the voice emitter is a small piece of glue
/// over `SFSpeechRecognizer` that feeds the recognized string into
/// the same descriptor list.
struct DebugCommandPaletteView: View {
    let descriptors: [CommandDescriptor]
    let dispatcher: AppCommandDispatcher
    @Binding var isPresented: Bool
    @State private var query: String = ""
    @FocusState private var queryFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            TextField("Type a command…", text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($queryFocused)
                .padding(12)
                .onSubmit { performFirstIfAvailable() }

            Divider()

            let matches = DebugCommandPalette.filter(descriptors, query: query)
            if matches.isEmpty {
                VStack {
                    Spacer()
                    Text("No matching commands")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                List(matches, id: \.command) { descriptor in
                    Button {
                        Task { await dispatcher.perform(descriptor.command) }
                        isPresented = false
                    } label: {
                        HStack {
                            Text(descriptor.title)
                            Spacer()
                            Text(descriptor.command.id)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.plain)
                .frame(maxHeight: 320)
            }

            Divider()

            HStack {
                Text("Esc to close · ⏎ to run")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(matches.count) command\(matches.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
        .frame(width: 520)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(radius: 20)
        .onAppear { queryFocused = true }
        // ⌘. is the standard SwiftUI cancel/escape for sheets; we
        // also support plain Escape via the keyboard-monitor path on
        // ContentView. Both routes set `isPresented = false`.
        .onExitCommand { isPresented = false }
    }

    private func performFirstIfAvailable() {
        let matches = DebugCommandPalette.filter(descriptors, query: query)
        guard let first = matches.first else { return }
        Task { await dispatcher.perform(first.command) }
        isPresented = false
    }
}
