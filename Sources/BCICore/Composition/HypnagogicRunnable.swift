import Foundation

/// The minimal lifecycle both hypnagogic loops share, so the composition root
/// can hold either the plain **mirror** loop (`HypnagogicDialogueLoop`) or the
/// **dialectic** loop (`HypnagogicDialecticLoop`) behind one reference and swap
/// between them without knowing which is running.
///
/// Actor-constrained: both conformers are actors, so `start`/`stop`/`isRunning`
/// are reached with `await` from the `@MainActor` view model.
public protocol HypnagogicRunnable: Actor {
    var isRunning: Bool { get }
    func start()
    func stop() async
}

extension HypnagogicDialogueLoop: HypnagogicRunnable {}
extension HypnagogicDialecticLoop: HypnagogicRunnable {}
