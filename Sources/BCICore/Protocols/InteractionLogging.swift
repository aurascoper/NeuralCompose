import Foundation

/// Pluggable sink for `TelemetryEvent`s. The live impl (`TelemetryLogger` in
/// `NeuralComposeApp`) appends JSONL to a local file; `NullInteractionLogger`
/// is the default everywhere the user hasn't opted in (see
/// `AppViewModel.interactionLoggingEnabled`, default `false`) and for tests.
///
/// Unlike `MetricsRecording`, this is not a hot-path type — call sites are
/// expected to gate on the opt-in toggle themselves and log at most once per
/// word commit, not per prediction tick.
public protocol InteractionLogging: Sendable {
    func log(_ event: TelemetryEvent) async
}

public struct NullInteractionLogger: InteractionLogging {
    public init() {}
    public func log(_ event: TelemetryEvent) async {}
}
