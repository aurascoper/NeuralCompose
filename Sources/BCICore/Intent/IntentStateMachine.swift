import Foundation

/// Application-level intent FSM. Maps `SmoothedIntent` events to one of
/// three application actions:
///
///   • `.advanceHighlight`  — move the highlight one slot in the carousel.
///   • `.commitActive`      — append the currently-highlighted token, request
///                            new predictions.
///   • `.noop`               — wait, don't change anything.
///
/// Advancing is purely gesture-driven (`.smoothed(.advance)`); `.timerTick`
/// is *not* an independent advance source — see its case below. Selection is
/// dwell-based (`IntentSmoother` fires `.selectActive` from sustained
/// `.rest`, not a distinct gesture), so there is no "auto-tick vs. gesture"
/// race to arbitrate here the way an earlier, timer-driven-advance design
/// would have needed.
///
/// Why an FSM rather than free-form logic:
///   • Selection should *not* fire mid-prediction while the LLM is still
///     producing candidates — we want to ignore selectActive while in
///     `.predicting`.
public struct IntentStateMachine: Sendable {

    public enum State: Sendable, Hashable {
        case idle             // Carousel quiet, no candidates yet
        case showingCandidates
        case predicting       // Waiting on LLM after a commit
    }

    public enum Action: Sendable, Hashable {
        case noop
        case advanceHighlight
        case commitActive
    }

    public enum Input: Sendable {
        case smoothed(SmoothedIntent)
        case timerTick
        case predictionsReady
        case predictionsRequested
        case reset
    }

    public private(set) var state: State = .idle

    public init() {}

    public mutating func step(_ input: Input) -> Action {
        switch (state, input) {

        // ── reset ────────────────────────────────────────────────────────
        case (_, .reset):
            state = .idle
            return .noop

        // ── waiting for first predictions ────────────────────────────────
        case (.idle, .predictionsReady):
            state = .showingCandidates
            return .noop

        case (.idle, _):
            return .noop

        // ── showing candidates ───────────────────────────────────────────
        // `.timerTick` no longer auto-advances: a blind fixed-interval
        // cycle would move the highlight off a candidate before the
        // multi-second dwell period `IntentSmoother` needs to confirm
        // .selectActive could ever complete. Advancing is now exclusively
        // gesture-driven via .smoothed(.advance) below. Kept as an explicit
        // case (not folded into the .idle/.predictionsRequested/
        // .predictionsReady noop case below) so a future reader sees the
        // reasoning at the exact spot where the old behavior lived, not
        // just absence of a case.
        case (.showingCandidates, .timerTick):
            return .noop

        case (.showingCandidates, .smoothed(.advance)):
            return .advanceHighlight

        case (.showingCandidates, .smoothed(.selectActive)):
            state = .predicting
            return .commitActive

        case (.showingCandidates, .smoothed(.idle)),
             (.showingCandidates, .predictionsRequested),
             (.showingCandidates, .predictionsReady):
            return .noop

        // ── predicting (LLM busy) ────────────────────────────────────────
        case (.predicting, .predictionsReady):
            state = .showingCandidates
            return .noop

        // Drop all signals while predicting — don't queue selects.
        case (.predicting, _):
            return .noop
        }
    }
}
