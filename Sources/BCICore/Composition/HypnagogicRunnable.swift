import Foundation

/// Observable execution state for a hypnagogic loop. It contains operational
/// metadata only: never a transcript, generated response, or audio payload.
public enum HypnagogicLoopPhase: String, Sendable, Equatable {
    case stopped
    case listening
    case generating
    case speaking
    case retrying
}

/// A compact diagnostic snapshot shared by both hypnagogic loop variants.
/// The app polls it for the diagnostics surface and health watchdog.
public struct HypnagogicLoopStatus: Sendable, Equatable {
    public let phase: HypnagogicLoopPhase
    public let lastFailure: String?
    public let turnIndex: Int
    public let lastTurnAt: Date?

    public init(
        phase: HypnagogicLoopPhase,
        lastFailure: String?,
        turnIndex: Int,
        lastTurnAt: Date?
    ) {
        self.phase = phase
        self.lastFailure = lastFailure
        self.turnIndex = turnIndex
        self.lastTurnAt = lastTurnAt
    }
}

/// The minimal lifecycle both hypnagogic loops share, so the composition root
/// can hold either the plain **mirror** loop (`HypnagogicDialogueLoop`) or the
/// **dialectic** loop (`HypnagogicDialecticLoop`) behind one reference and swap
/// between them without knowing which is running.
///
/// Actor-constrained: both conformers are actors, so lifecycle and status are
/// reached with `await` from the `@MainActor` view model.
public protocol HypnagogicRunnable: Actor {
    var isRunning: Bool { get }
    var status: HypnagogicLoopStatus { get }
    func start()
    func stop() async
}

extension HypnagogicDialogueLoop: HypnagogicRunnable {}
extension HypnagogicDialecticLoop: HypnagogicRunnable {}
