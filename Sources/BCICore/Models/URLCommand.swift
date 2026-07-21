import Foundation

/// Parses an incoming `neuralcompose://` URL into an app action. This is the
/// "Apple Shortcuts" emitter anticipated in `AppCommand`'s doc comment: a Siri
/// Shortcut runs "Open URL `neuralcompose://speak?text=…`", which lands here and
/// routes into the same `AppCommand` → `AppCommandDispatcher` seam every other
/// control surface uses. Pure and Foundation-only, so it's unit-testable without
/// the app running.
///
/// Grammar (`neuralcompose://<action>[?text=<t>]`), action from the URL host:
///   - `speak`            → `.speakComposed` (read the current composed sentence)
///   - `speak?text=<t>`   → `.speak(text:)`  (read arbitrary text — "speak this")
///   - `refine`           → `.dispatch(.refine)`
///   - `dictate`          → `.dispatch(.startDictation)`
///   - `stop-dictation`   → `.dispatch(.stopDictation)`
///   - `reset`            → `.dispatch(.resetComposition)`
///   - anything else / wrong scheme → `nil` (ignored, never throws).
public enum URLCommand: Equatable, Sendable {
    case speakComposed
    case speak(text: String)
    case dispatch(AppCommand)

    /// The registered URL scheme (see `CFBundleURLTypes` in Info.plist).
    public static let scheme = "neuralcompose"

    public static func parse(_ url: URL) -> URLCommand? {
        guard url.scheme?.lowercased() == scheme,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        // Action is the authority (host) for `scheme://action`, falling back to
        // the first path segment for `scheme:action` opaque forms.
        let action = (components.host
            ?? components.path.split(separator: "/").first.map(String.init)
            ?? "").lowercased()
        switch action {
        case "speak":
            if let text = components.queryItems?.first(where: { $0.name == "text" })?.value,
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return .speak(text: text)
            }
            return .speakComposed
        case "refine":                    return .dispatch(.refine)
        case "dictate", "start-dictation": return .dispatch(.startDictation)
        case "stop-dictation":            return .dispatch(.stopDictation)
        case "reset":                     return .dispatch(.resetComposition)
        default:                          return nil
        }
    }
}
