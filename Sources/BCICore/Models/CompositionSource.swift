import Foundation

/// Identifies where text merged into `TextCompositionController.composed`
/// actually came from. EEG commits are documented here for completeness but
/// never actually pass through this enum at a call site — they stay on the
/// FSM-driven `commitActive` path (see `TextCompositionController.handleAction`),
/// since the carousel/highlight semantics that path needs don't apply to a
/// flat external string. `.dictation`/`.importedText` funnel through
/// `appendExternalText(_:source:)` (append); `.automation` funnels through
/// `applyRefinement(_:)` (replace) — see each method's doc comment for why
/// the merge semantics differ.
public enum CompositionSource: String, Sendable, Codable {
    case eeg
    case dictation
    case importedText
    case automation
}
