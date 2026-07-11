import Foundation

/// Pluggable metrics sink. The live impl (`MetricsCollector`) keeps a
/// bounded ring of recent timings + counters that the UI samples on a 4 Hz
/// timer. A `NullMetricsRecorder` is also provided for tests.
///
/// Recorder methods must be cheap and non-blocking; they are called from
/// the EEG, classifier, and predictor hot paths.
public protocol MetricsRecording: Sendable {
    func recordWindowing(durationMicros: UInt64)
    func recordClassification(durationMicros: UInt64, computeMode: ClassifierComputeMode)
    func recordPrediction(durationMicros: UInt64, modelIdentifier: String)
    func recordCarouselTick()
    func recordSelection(committedToken: String)
    func recordIntent(_ intent: SmoothedIntent)
    func recordError(_ error: BCIError)
    func recordExternalText(source: CompositionSource, wordCount: Int)
}

public struct NullMetricsRecorder: MetricsRecording {
    public init() {}
    public func recordWindowing(durationMicros: UInt64) {}
    public func recordClassification(durationMicros: UInt64, computeMode: ClassifierComputeMode) {}
    public func recordPrediction(durationMicros: UInt64, modelIdentifier: String) {}
    public func recordCarouselTick() {}
    public func recordSelection(committedToken: String) {}
    public func recordIntent(_ intent: SmoothedIntent) {}
    public func recordError(_ error: BCIError) {}
    public func recordExternalText(source: CompositionSource, wordCount: Int) {}
}
