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
    /// Semantic sentence embedder feeding the 3D workspace. Lives on the
    /// composition root (not `PredictorFactory.Resolved`) so text embedding
    /// stays decoupled from the LLM predictor — a real Core ML/MLX embedder is
    /// its own concern, not a widening of the generation seam. Defaults to the
    /// dependency-free deterministic stub; test-overridable like everything
    /// else here.
    public let sentenceEmbedder: any SentenceEmbedder
    /// Milestone B state source — real MLX-backed if `Models/EEGEncoder/`
    /// resolves and its anchor space is trusted, stub otherwise. Resolved
    /// *after* `sentenceEmbedder` in `makeDefault()`: the estimator needs
    /// the already-built embedder for its honesty gate and to rebuild the
    /// anchor table (see `SpectralStateEstimator`'s doc comment).
    public let spectralEstimatorResolved: SpectralStateEstimatorFactory.Resolved
    /// Sink for opt-in local interaction logging (see
    /// `docs/architecture/decision-log/ADR-005-local-interaction-logging.md`).
    /// Defaults to a no-op here — same "stub-safe by default" shape as
    /// `sentenceEmbedder`/`spectralEstimatorResolved` — so constructing an
    /// `AppContainer` directly (tests, previews) never touches disk unless a
    /// caller explicitly opts in. `makeDefault()` wires the real
    /// `TelemetryLogger`; `AppViewModel.interactionLoggingEnabled` (off by
    /// default) gates whether it's ever actually called.
    public let interactionLogger: any InteractionLogging

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
        smootherConfig: IntentSmoother.Config = .init(),
        sentenceEmbedder: any SentenceEmbedder = DeterministicSentenceEmbedder(),
        spectralEstimatorResolved: SpectralStateEstimatorFactory.Resolved = .init(
            estimator: StubSpectralStateEstimator(), kind: .stub, warning: nil
        ),
        interactionLogger: any InteractionLogging = NullInteractionLogger()
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
        self.sentenceEmbedder = sentenceEmbedder
        self.spectralEstimatorResolved = spectralEstimatorResolved
        self.interactionLogger = interactionLogger
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
        BCILog.predictor.notice("predictor backend: \(predictor.kind.rawValue, privacy: .public)")
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

        let sentenceEmbedder: any SentenceEmbedder
        let sentenceEmbedderBackend: String
        do {
            sentenceEmbedder = try CoreMLSentenceEmbedder(
                modelDirectory: URL(fileURLWithPath: "Models/BGE-small-en-v1.5")
            )
            sentenceEmbedderBackend = "coreml"
        } catch {
            sentenceEmbedder = DeterministicSentenceEmbedder()
            sentenceEmbedderBackend = "stub"
        }
        BCILog.embedding.notice("sentenceEmbedder backend: \(sentenceEmbedderBackend, privacy: .public)")

        // Resolved after sentenceEmbedder — needs it for the honesty gate
        // and to rebuild the anchor table (see SpectralStateEstimator).
        let spectralEstimator = await SpectralStateEstimatorFactory.live(sentenceEmbedder: sentenceEmbedder)
        BCILog.spectral.notice("spectral estimator backend: \(spectralEstimator.kind.rawValue, privacy: .public)")

        // Always constructed — writes nothing until AppViewModel's opt-in
        // interactionLoggingEnabled toggle (off by default) actually calls
        // log(_:). See ADR-005-local-interaction-logging.md.
        let interactionLogger = TelemetryLogger(directory: TelemetryLogger.defaultDirectory())

        return AppContainer(
            streamResolved: stream,
            classifierResolved: classifier,
            predictorResolved: predictor,
            voiceOutputResolved: voiceOutput,
            voiceInputResolved: voiceInput,
            voiceCommandResolved: voiceCommand,
            metrics: metrics,
            windowingConfig: windowingConfig,
            sentenceEmbedder: sentenceEmbedder,
            spectralEstimatorResolved: spectralEstimator,
            interactionLogger: interactionLogger
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
