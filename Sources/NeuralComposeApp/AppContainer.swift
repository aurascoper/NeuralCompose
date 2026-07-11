import Foundation
import BCICore
import BCIEEG
import BCIClassifier
import BCILLM
import BCIVoice

/// Composition root. Knows nothing about SwiftUI; constructs the pipeline
/// pieces and hands them to the view model. Kept here so previews and unit
/// tests can swap implementations without touching SwiftUI.
public struct AppContainer: Sendable {
    public let streamResolved: EEGStreamFactory.Resolved
    public let classifierResolved: ClassifierFactory.Resolved
    public let predictorResolved: PredictorFactory.Resolved
    public let voiceOutputResolved: VoiceOutputFactory.Resolved
    public let voiceInputResolved: VoiceInputFactory.Resolved
    public let voiceCommandResolved: VoiceCommandFactory.Resolved
    public let metrics: MetricsCollector
    public let windowingConfig: EEGWindowingConfig
    public let smootherConfig: IntentSmoother.Config

    public var pipelineMode: PipelineMode {
        PipelineMode(
            acquisition: streamResolved.acquisition,
            transport: streamResolved.transport,
            sourceProfile: streamResolved.profile,
            classifier: classifierResolved.kind,
            predictor: predictorResolved.kind,
            transportDetail: Self.transportDetail(for: streamResolved.stream)
        )
    }

    /// Extra detail for the privacy banner beyond `sourceProfile.displayName`
    /// — currently just the OSC bound port/interface, since that's the one
    /// transport where "which port, which interface" is actually useful to
    /// see without grepping logs. `nil` for every other transport.
    ///
    /// Internal, not `private`: `AppViewModel.publishMode` needs this too —
    /// see that function's doc comment for why the initial `pipelineMode`
    /// (built from this computed property, here) and the one it publishes
    /// on every supervisor loop iteration have to compute this the same way.
    static func transportDetail(for stream: any EEGStreaming) -> String? {
        guard let oscStream = stream as? MindMonitorOSCStream else { return nil }
        let diagnostics = oscStream.currentDiagnostics()
        guard let boundPort = diagnostics.boundPort else { return nil }
        if let interfaceName = diagnostics.localInterfaceName {
            return "UDP \(boundPort) · \(interfaceName)"
        }
        return "UDP \(boundPort)"
    }

    public init(
        streamResolved: EEGStreamFactory.Resolved,
        classifierResolved: ClassifierFactory.Resolved,
        predictorResolved: PredictorFactory.Resolved,
        voiceOutputResolved: VoiceOutputFactory.Resolved,
        voiceInputResolved: VoiceInputFactory.Resolved,
        voiceCommandResolved: VoiceCommandFactory.Resolved = VoiceCommandFactory.live(overrideAvailability: false),
        metrics: MetricsCollector,
        windowingConfig: EEGWindowingConfig,
        smootherConfig: IntentSmoother.Config = .init()
    ) {
        self.streamResolved = streamResolved
        self.classifierResolved = classifierResolved
        self.predictorResolved = predictorResolved
        self.voiceOutputResolved = voiceOutputResolved
        self.voiceInputResolved = voiceInputResolved
        self.voiceCommandResolved = voiceCommandResolved
        self.metrics = metrics
        self.windowingConfig = windowingConfig
        self.smootherConfig = smootherConfig
    }

    /// Build a container from the environment. This is what the App entry
    /// point calls at launch.
    public static func makeDefault() async -> AppContainer {
        let profile = profileFromEnvironment()
        let playbackPath = ProcessInfo.processInfo.environment["NEURALCOMPOSE_PLAYBACK_PATH"]
        let oscPort = ProcessInfo.processInfo.environment["NEURALCOMPOSE_OSC_PORT"]
            .flatMap(UInt16.init) ?? 5000
        let stream = EEGStreamFactory.make(profile: profile, playbackPath: playbackPath, oscPort: oscPort)
        let classifier = ClassifierFactory.live()
        let predictor = await PredictorFactory.live()
        let voiceOutput = VoiceOutputFactory.live()
        let voiceInput = VoiceInputFactory.live()
        // The voice command recognizer is constructed with a
        // parser closure that wraps `FuzzyCommandRecognizer`
        // (ASR-tolerant token-level matching — see that type's
        // doc comment). The closure captures the recognizer by
        // reference; the recognizer is stateless and Sendable.
        let commandRecognizer = FuzzyCommandRecognizer()
        let voiceCommand = VoiceCommandFactory.live(
            parser: { text, descriptors in
                commandRecognizer.recognize(text, in: descriptors)
            },
            vocabulary: DefaultCommandDescriptors.all
        )
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
            voiceOutputResolved: voiceOutput,
            voiceInputResolved: voiceInput,
            voiceCommandResolved: voiceCommand,
            metrics: metrics,
            windowingConfig: windowingConfig
        )
    }

    private static func profileFromEnvironment() -> MuseBoardProfile {
        let raw = ProcessInfo.processInfo.environment["NEURALCOMPOSE_BOARD_PROFILE"] ?? "synthetic"
        switch raw.lowercased() {
        case "muse2", "musetwo", "muse2-ble", "musetwo-ble":
            return .museTwoNativeBLE
        case "muse2-bled", "musetwo-bled", "muse2bled":
            return .museTwoBLED
        case "muses", "muses-ble":
            return .museSNativeBLE
        case "muses-bled", "musesbled":
            return .museSBLED
        case "musesathena", "athena", "muses-athena":
            return .museSAthena
        case "playback":
            return .playback
        case "osc", "oscremote", "osc-remote", "mindmonitor":
            return .oscRemote
        default:
            return .synthetic
        }
    }
}
