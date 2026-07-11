import Foundation

/// Live counters + rolling-window timing for the diagnostics view.
///
/// The pipeline calls into this on the hot path; everything here must be
/// cheap and lock-free at call sites. We store atomics for counters and a
/// small fixed-size ring of recent timings per stage.
///
/// Thread safety: the public methods take `self` as `Sendable` and protect
/// shared state with an `OSAllocatedUnfairLock` — actor isolation would add
/// async hops to every recorded sample, which we don't want on the EEG hot
/// path.
import os

public final class MetricsCollector: MetricsRecording, @unchecked Sendable {

    public struct Stage: Sendable, Hashable {
        public var samples: [UInt64] = []
        public var count: UInt64 = 0
        public mutating func record(_ micros: UInt64, ringSize: Int) {
            count &+= 1
            samples.append(micros)
            if samples.count > ringSize { samples.removeFirst(samples.count - ringSize) }
        }
        public var avgMicros: Double {
            guard !samples.isEmpty else { return 0 }
            return Double(samples.reduce(0, +)) / Double(samples.count)
        }
        public var p95Micros: UInt64 {
            guard !samples.isEmpty else { return 0 }
            let sorted = samples.sorted()
            let idx = min(sorted.count - 1, Int(0.95 * Double(sorted.count)))
            return sorted[idx]
        }
    }

    public struct Snapshot: Sendable, Hashable {
        public let windowing: Stage
        public let classification: Stage
        public let prediction: Stage
        public let carouselTicks: UInt64
        public let selectionCommits: UInt64
        public let recentIntents: [SmoothedIntent]
        public let lastErrorDescription: String?
        public let classifierMode: ClassifierComputeMode
        public let predictorIdentifier: String
    }

    private let lock = OSAllocatedUnfairLock()
    private let ringSize: Int

    // Guarded state.
    private var windowing      = Stage()
    private var classification = Stage()
    private var prediction     = Stage()
    private var carouselTicks: UInt64 = 0
    private var selectionCommits: UInt64 = 0
    private var recentIntents: [SmoothedIntent] = []
    private var lastErrorDescription: String?
    private var classifierMode: ClassifierComputeMode = .cpuAndNeuralEngine
    private var predictorIdentifier: String = "stub"
    private var externalTextWordCounts: [CompositionSource: Int] = [:]

    public init(ringSize: Int = 128) {
        self.ringSize = ringSize
    }

    // MARK: MetricsRecording

    public func recordWindowing(durationMicros: UInt64) {
        lock.withLock { windowing.record(durationMicros, ringSize: ringSize) }
    }
    public func recordClassification(durationMicros: UInt64, computeMode: ClassifierComputeMode) {
        lock.withLock {
            classification.record(durationMicros, ringSize: ringSize)
            classifierMode = computeMode
        }
    }
    public func recordPrediction(durationMicros: UInt64, modelIdentifier: String) {
        lock.withLock {
            prediction.record(durationMicros, ringSize: ringSize)
            predictorIdentifier = modelIdentifier
        }
    }
    public func recordCarouselTick() {
        lock.withLock { carouselTicks &+= 1 }
    }
    public func recordSelection(committedToken: String) {
        lock.withLock { selectionCommits &+= 1 }
    }
    public func recordIntent(_ intent: SmoothedIntent) {
        lock.withLock {
            recentIntents.append(intent)
            if recentIntents.count > 16 { recentIntents.removeFirst(recentIntents.count - 16) }
        }
    }
    public func recordError(_ error: BCIError) {
        lock.withLock { lastErrorDescription = error.description }
    }
    public func recordExternalText(source: CompositionSource, wordCount: Int) {
        lock.withLock { externalTextWordCounts[source, default: 0] += wordCount }
    }

    public func snapshot() -> Snapshot {
        lock.withLock {
            Snapshot(
                windowing: windowing,
                classification: classification,
                prediction: prediction,
                carouselTicks: carouselTicks,
                selectionCommits: selectionCommits,
                recentIntents: recentIntents,
                lastErrorDescription: lastErrorDescription,
                classifierMode: classifierMode,
                predictorIdentifier: predictorIdentifier
            )
        }
    }
}
