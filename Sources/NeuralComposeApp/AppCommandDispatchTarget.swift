import Foundation
import BCICore

/// The minimal surface of `AppViewModel` that `AppCommandDispatcher`
/// needs to call. Lets the dispatcher depend on a protocol rather
/// than the concrete `AppViewModel` class — same pattern as
/// `EEGStreaming`, `NextWordPredicting`, etc. in the rest of the
/// codebase. Lets tests substitute a spy that records every dispatch
/// without spinning up the full pipeline.
///
/// `AppViewModel` is the canonical implementation. The protocol
/// captures only what the dispatcher exercises today; new members
/// are added when a new `AppCommand` case needs them.
@MainActor
public protocol AppCommandDispatchTarget: AnyObject {
    var pendingWindowOpen: String? { get set }
    var pendingTab: PendingTab? { get set }

    func startCalibrationRecording() async
    func stopCalibrationRecording() async
    func startImaginedSpeechSession() async
    func resetComposition() async
    func speak() async
    func refineComposedText() async
    func startDictation() async
    func stopDictation() async
    func startCommandListening() async
    func stopCommandListening() async
}

/// Transient view-side navigation requests published by the dispatcher
/// and consumed by SwiftUI's `.onChange`. Using a published field
/// rather than calling `openWindow(id:)` directly from the
/// dispatcher's `perform(_:)` preserves the
/// "dispatcher is `@MainActor` but not a SwiftUI view" boundary —
/// `openWindow` requires SwiftUI's environment and cannot be invoked
/// from a non-view context.
///
/// The view consumes the field, performs the SwiftUI action, then
/// immediately clears the field so subsequent emissions re-fire.
public enum PendingTab: Sendable, Equatable {
    case production
    case research
    case calibration
}
