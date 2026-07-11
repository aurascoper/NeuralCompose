import Foundation

/// Classic Levenshtein edit distance and a length-normalized
/// similarity derived from it. Pure, allocation-light (two rolling
/// rows), no dependencies — used by `FuzzyCommandRecognizer` to
/// tolerate ASR substitutions/insertions/deletions that an exact or
/// prefix match would reject outright.
enum Levenshtein {

    /// Minimum single-character edits (insert/delete/substitute) to
    /// turn `a` into `b`.
    static func distance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }

        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)

        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = Swift.min(
                    previous[j] + 1,       // deletion
                    current[j - 1] + 1,    // insertion
                    previous[j - 1] + cost // substitution
                )
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }

    /// `1 - distance / max(a.count, b.count)`, clamped to `[0, 1]`.
    /// `1.0` means identical strings; `0.0` means maximally different
    /// (or both empty is treated as `0.0` — there's nothing to match).
    static func similarity(_ a: String, _ b: String) -> Double {
        let maxLen = Swift.max(a.count, b.count)
        guard maxLen > 0 else { return 0 }
        return 1.0 - Double(distance(a, b)) / Double(maxLen)
    }
}
