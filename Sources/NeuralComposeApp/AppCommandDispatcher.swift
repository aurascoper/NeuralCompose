import Foundation
import BCICore

/// Single place that turns an `AppCommand` into a side effect.
///
/// Every emitter (existing buttons, menu items, keyboard shortcuts,
/// the debug palette in commit 3, the future voice / Shortcuts / MCP
/// emitters) is dumb: it produces an `AppCommand`, the dispatcher
/// executes it. Adding a new command means adding a case to the enum
/// + a switch arm here; emitters don't change.
///
/// **SwiftUI boundary.** `AppViewModel` is `@MainActor` but not a
/// SwiftUI view, so it cannot call `openWindow(id:)` directly. The
/// dispatcher publishes transient values on the target's
/// `pendingWindowOpen` / `pendingTab` properties; the consuming view
/// observes via `.onChange`, performs the SwiftUI action, and
/// immediately clears the field so subsequent emissions re-fire.
///
/// **Threading.** The dispatcher is `@MainActor`. The `perform(_:)`
/// method is `async` because the underlying target methods
/// (`startCalibrationRecording`, `speak`, etc.) are themselves
/// `async`. The dispatcher doesn't introduce any new concurrency
/// beyond what the target already exposes.
///
/// **Lifecycle.** Holds the target as a *weak* reference so a
/// short-lived dispatcher doesn't extend the target's lifetime
/// past its natural scope. In practice, the dispatcher's lifetime
/// is the same as the target's (both are owned by `AppLoader`), but
/// the weak ref documents the relationship clearly.
@MainActor
public final class AppCommandDispatcher {

    private weak var target: (any AppCommandDispatchTarget)?
    private let descriptors: [CommandDescriptor]

    public init(target: any AppCommandDispatchTarget, descriptors: [CommandDescriptor] = DefaultCommandDescriptors.all) {
        self.target = target
        self.descriptors = descriptors
    }

    /// The vocabulary this dispatcher was initialized with. Exposed
    /// so the debug palette (and any future emitter) can use the
    /// same list the dispatcher was built with — single source of
    /// truth, no parallel tables.
    public var commandDescriptors: [CommandDescriptor] { descriptors }

    /// Performs the side effect for `command`. Returns silently if
    /// the underlying target has been deallocated (the weak ref
    /// became nil) — the caller cannot meaningfully do anything in
    /// that case, and silently no-oping is the least-surprising
    /// behavior for a UI event handler.
    public func perform(_ command: AppCommand) async {
        guard let target else { return }
        switch command {
        case .openPhaseBDebug:
            target.pendingWindowOpen = "phase-b-debug"
        case .startRecording:
            await target.startCalibrationRecording()
        case .stopRecording:
            await target.stopCalibrationRecording()
        case .beginCalibration:
            await target.startCalibrationRecording()
            target.pendingTab = .calibration
        case .beginSleepProtocol:
            await target.startImaginedSpeechSession()
            target.pendingTab = .research
        case .resetComposition:
            await target.resetComposition()
        case .speak:
            await target.speak()
        case .refine:
            await target.refineComposedText()
        case .startDictation:
            await target.startDictation()
        case .stopDictation:
            await target.stopDictation()
        }
    }
}
