import Foundation

/// Canonical set of application-level commands that any control surface
/// (button, menu, keyboard shortcut, debug palette, voice, future
/// Shortcuts / MCP / AppleScript emitters) can produce.
///
/// **This is the single source of truth for "what the app can do."** Every
/// emitter is dumb: it produces an `AppCommand`, the dispatcher executes it.
/// Adding a new command means adding a case here + a switch arm in
/// `AppCommandDispatcher`; emitters don't change.
///
/// Out of the original 9-candidate list, only 10 ship in this iteration.
/// The deferred cases (`.open3DWorkspace`, `.startPlayback`,
/// `.stopPlayback`, `.exportSession`) are documented in
/// `.hermes/plans/appcommand-architecture.md` and will be appended when
/// the underlying affordances exist.
public enum AppCommand: Sendable, Equatable, Hashable {
    case openPhaseBDebug
    case startRecording
    case stopRecording
    case beginCalibration
    case beginSleepProtocol
    case resetComposition
    case speak
    case refine
    case startDictation
    case stopDictation
}

extension AppCommand {
    /// Stable, never-changing string identifier for this command.
    /// Distinct from the Swift case name (which can be renamed in code) and
    /// from the user-facing display title (which can be reworded). The id
    /// is the canonical key for:
    ///   - telemetry and voice logs
    ///   - command history and replay
    ///   - future MCP / Apple Shortcuts / AppleScript integrations
    ///   - serialization across releases
    ///
    /// Format: `<domain>.<verb>[-<noun>]`. Once an id ships, it does not
    /// change — adding a new command means a new id, not a renamed one.
    public var id: String {
        switch self {
        case .openPhaseBDebug:    return "debug.phase-b"
        case .startRecording:     return "record.start"
        case .stopRecording:      return "record.stop"
        case .beginCalibration:   return "calibration.begin"
        case .beginSleepProtocol: return "protocol.sleep-begin"
        case .resetComposition:   return "composition.reset"
        case .speak:              return "tts.speak"
        case .refine:             return "refine.run"
        case .startDictation:     return "dictation.start"
        case .stopDictation:      return "dictation.stop"
        }
    }
}
