import Foundation

/// One row in the application's command vocabulary. The descriptor is the
/// single source of truth for "this command exists, here's how the user
/// refers to it, here's the title to show in the palette."
///
/// Every recognizer (stub, future speech, future embedding, future
/// Shortcuts) and the debug palette consume the same descriptor list.
/// Adding a new command means one new enum case in `AppCommand` and one
/// new `CommandDescriptor` entry here — recognizers and the palette
/// pick it up automatically.
public struct CommandDescriptor: Sendable, Equatable, Hashable {
    /// The command this descriptor refers to.
    public let command: AppCommand

    /// Human-friendly title shown in the palette. Not the canonical
    /// identifier — that is `command.id`. This string is for display
    /// and can be reworded in a future release without breaking
    /// telemetry / replay / MCP integrations.
    public let title: String

    /// Natural variations the user might say or type to invoke this
    /// command. Matched by every recognizer (case-insensitive, with
    /// politeness prefix/suffix stripping — see
    /// `StubCommandRecognizer` for the exact heuristic).
    ///
    /// Order matters when multiple aliases match: the first one that
    /// the recognizer accepts wins. Put the most-specific, most-natural
    /// aliases first.
    public let aliases: [String]

    public init(command: AppCommand, title: String, aliases: [String]) {
        self.command = command
        self.title = title
        self.aliases = aliases
    }
}
