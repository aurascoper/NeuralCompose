import Foundation
import BCICore
import BCIEEG
import BCIClassifier
import BCILLM

/// Composition root. Knows nothing about SwiftUI; constructs the pipeline
/// pieces and hands them to the view model. Kept here so previews and unit
/// tests can swap implementations without touching SwiftUI.
public struct AppContainer: Sendable {
    public let streamResolved: EEGStreamFactory.Resolved
    public let classifierResolved: ClassifierFactory.Resolved
    public let predictorResolved: PredictorFactory.Resolved
    public let metrics: MetricsCollector
    public let windowingConfig: EEGWindowingConfig
    public let smootherConfig: IntentSmoother.Config

    public var pipelineMode: PipelineMode {
        PipelineMode(
            source: streamResolved.source,
            sourceProfile: streamResolved.profile,
            classifier: classifierResolved.kind,
            predictor: predictorResolved.kind
        )
    }

    public init(
        streamResolved: EEGStreamFactory.Resolved,
        classifierResolved: ClassifierFactory.Resolved,
        predictorResolved: PredictorFactory.Resolved,
        metrics: MetricsCollector,
        windowingConfig: EEGWindowingConfig,
        smootherConfig: IntentSmoother.Config = .init()
    ) {
        self.streamResolved = streamResolved
        self.classifierResolved = classifierResolved
        self.predictorResolved = predictorResolved
        self.metrics = metrics
        self.windowingConfig = windowingConfig
        self.smootherConfig = smootherConfig
    }

    /// Build a container from the environment. This is what the App entry
    /// point calls at launch.
    public static func makeDefault() async -> AppContainer {
        let profile = profileFromEnvironment()
        let playbackPath = ProcessInfo.processInfo.environment["NEURALCOMPOSE_PLAYBACK_PATH"]
        let stream = EEGStreamFactory.make(profile: profile, playbackPath: playbackPath)
        let classifier = ClassifierFactory.live()
        let predictor = await PredictorFactory.live()
        let metrics = MetricsCollector()
        let windowingConfig = EEGWindowingConfig(
            windowSeconds: 2.0,
            strideSeconds: 1.0,
            sampleRate: stream.stream.effectiveSampleRate,
            channelCount: stream.stream.channelCount
        )
        return AppContainer(
            streamResolved: stream,
            classifierResolved: classifier,
            predictorResolved: predictor,
            metrics: metrics,
            windowingConfig: windowingConfig
        )
    }

    private static func profileFromEnvironment() -> MuseBoardProfile {
        let raw = ProcessInfo.processInfo.environment["NEURALCOMPOSE_BOARD_PROFILE"] ?? "synthetic"
        switch raw.lowercased() {
        case "muse2", "musetwo":          return .museTwo
        case "muses":                     return .museS
        case "musesathena", "athena":     return .museSAthena
        case "playback":                  return .playback
        default:                          return .synthetic
        }
    }
}
