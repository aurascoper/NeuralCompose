import Foundation

/// Application-level intent FSM. Maps `SmoothedIntent` events plus the
/// carousel tick to one of three application actions:
///
///   • `.advanceHighlight`  — move the highlight one slot in the carousel.
///   • `.commitActive`      — append the currently-highlighted token, request
///                            new predictions.
///   • `.noop`               — wait, don't change anything.
///
/// Why an FSM rather than free-form logic:
///   • Selection should *not* fire mid-prediction while the LLM is still
///     producing candidates — we want to ignore selectActive while in
///     `.predicting`.
///   • Advance should be ignored during the auto-tick grace period so the
///     UI doesn't appear jittery — the user's intent compete with the timer.
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
        case (.showingCandidates, .timerTick):
            return .advanceHighlight

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
