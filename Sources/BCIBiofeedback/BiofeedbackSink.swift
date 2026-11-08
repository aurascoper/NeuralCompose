import Foundation

/// Where biofeedback outputs go. The egress has exactly two production
/// conformers (`OSCUDPSender`, `CoreMIDIVirtualSource`) and two for tests
/// and offline work (`RecordingBiofeedbackSink`, `NullBiofeedbackSink`).
/// A sink receives already-shaped outputs and never sees EEG, a frame or
/// a mapping; it is a dumb pipe by design so the privacy audit stops at
/// `FeatureMapper` and `MindMonitorMirror`.
///
/// Conformers may drop the cases they cannot carry. They must not block
/// the caller on network or device I/O; `emit` is `async` so an actor
/// conformer can serialise its own sends.
///
/// **API stability.** Frozen with this signature per Principle 4: new
/// capabilities (batching hints, timestamps) arrive as new optional
/// methods with default implementations, never as changes to `emit`.
public protocol BiofeedbackSink: Sendable {
    func emit(_ outputs: [BiofeedbackOutput]) async
}

/// Fan-out to several sinks in order.
public struct CompositeBiofeedbackSink: BiofeedbackSink {
    public let sinks: [any BiofeedbackSink]

    public init(_ sinks: [any BiofeedbackSink]) {
        self.sinks = sinks
    }

    public func emit(_ outputs: [BiofeedbackOutput]) async {
        for sink in sinks {
            await sink.emit(outputs)
        }
    }
}

/// Keeps everything it is given, for tests and for building replay
/// fixtures.
public actor RecordingBiofeedbackSink: BiofeedbackSink {
    public private(set) var outputs: [BiofeedbackOutput] = []

    public init() {}

    public func emit(_ outputs: [BiofeedbackOutput]) async {
        self.outputs.append(contentsOf: outputs)
    }

    public func clear() {
        outputs.removeAll()
    }
}

/// Discards everything. The stub that ships with the protocol, and the
/// sink the app uses while the egress feature is disabled so the mapper
/// path stays exercised without anything leaving the process.
public struct NullBiofeedbackSink: BiofeedbackSink {
    public init() {}
    public func emit(_ outputs: [BiofeedbackOutput]) async {}
}
