import Foundation
import BCICore
import BCIBridge
import BCIEEG
import BCIClassifier
import BCILLM
import BCIVoice
import BCIBiofeedback
import WorldModelDemo

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
    /// The resolved sentence-embedder backend ("coreml" | "stub"). The embedder
    /// protocol carries no kind of its own, so we capture it here for the health
    /// watchdog: a stub embedder silently degrades both the dialectic scoring
    /// AND the spectral estimator's honesty gate.
    public let sentenceEmbedderKind: String
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
    /// Separate local-only recorder for paired EEG-window/action transitions.
    /// It is inert by default and independently gated by
    /// `AppViewModel.jepaTransitionCaptureEnabled`; do not route this through
    /// `TelemetryEvent`, whose deliberately narrower privacy contract remains
    /// unchanged.
    public let jepaTransitionCapture: any JEPATransitionCapturing
    /// Synthetic-task JEPA+MPC research demo (see `Sources/WorldModelDemo/`,
    /// `WorldModel/README.md`) — CoreML/ANE if `Models/WorldModelDemo/`
    /// resolves, a baseline proportional controller otherwise. Entirely
    /// separate from the real pipeline: never reads EEG, never actuates
    /// generation, gated by `AppViewModel.worldModelDemoEnabled` (off by
    /// default). Deliberately excluded from `PipelineMode` — that type
    /// drives the real pipeline's status banner.
    public let worldModelDemoResolved: WorldModelDemoFactory.Resolved
    /// `~/Documents/NeuralCompose/voice-profile.json` as loaded at launch (nil if
    /// absent or malformed). Kept for the hypnagogic listener, which the view
    /// model builds lazily and which reads the recognition vocabulary from it.
    public let voiceProfile: VoiceProfile?
    /// Biofeedback egress (ADR-011, registry entry 10). `nil` unless the
    /// launch environment enabled at least one transport, so constructing an
    /// `AppContainer` directly (tests, previews) never opens a UDP socket or
    /// a CoreMIDI port. When present, `AppViewModel` feeds it the raw window
    /// (before channel substitution), the classifier's intent, IMU samples,
    /// and, only with the explicit raw toggle, raw EEG samples.
    public let biofeedback: BiofeedbackCoordinator?
    /// The resolved egress configuration, kept beside the coordinator so the
    /// privacy indicator can name the tier (MIDI, loopback, LAN) and the raw
    /// toggle without reaching into the actor.
    public let biofeedbackConfiguration: BiofeedbackConfiguration

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
        sentenceEmbedderKind: String = "stub",
        spectralEstimatorResolved: SpectralStateEstimatorFactory.Resolved = .init(
            estimator: StubSpectralStateEstimator(), kind: .stub, warning: nil
        ),
        interactionLogger: any InteractionLogging = NullInteractionLogger(),
        jepaTransitionCapture: any JEPATransitionCapturing = NullJEPATransitionCapture(),
        worldModelDemoResolved: WorldModelDemoFactory.Resolved = .init(
            engine: BaselineWorldModelDemoPlanner(), kind: .baseline, warning: nil
        ),
        voiceProfile: VoiceProfile? = nil,
        biofeedback: BiofeedbackCoordinator? = nil,
        biofeedbackConfiguration: BiofeedbackConfiguration = .disabled
    ) {
        self.voiceProfile = voiceProfile
        self.biofeedback = biofeedback
        self.biofeedbackConfiguration = biofeedbackConfiguration
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
        self.sentenceEmbedderKind = sentenceEmbedderKind
        self.spectralEstimatorResolved = spectralEstimatorResolved
        self.interactionLogger = interactionLogger
        self.jepaTransitionCapture = jepaTransitionCapture
        self.worldModelDemoResolved = worldModelDemoResolved
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
        // Persisted voice preferences (~/Documents/NeuralCompose/voice-profile.json,
        // written by Scripts/voice-profile.py) OVERRIDE the env vars, so the chosen
        // Personal Voice persists across launches without any flags.
        let voiceProfile = VoiceProfile.loadDefault()
        let usePersonalVoice = voiceProfile?.usePersonalVoice
            ?? (ProcessInfo.processInfo.environment["NEURALCOMPOSE_PERSONAL_VOICE"] == "1")
        // Personal Voice is opt-in. Personal voices appear in speechVoices() only
        // AFTER authorization is established in THIS process, so we AWAIT it BEFORE
        // resolving the synthesizer's voice — otherwise selection runs first (at
        // construction) and always misses the personal voice. After the one-time
        // system grant this returns immediately (no prompt); only the first grant
        // blocks on the user, and only for the bundled app (a no-bundle `swift run`
        // can't present the prompt). The grant is cdhash-pinned — sign with
        // Scripts/sign-app-local.sh to persist it across rebuilds.
        if usePersonalVoice {
            let granted = await AVSpeechSynthesizerService.requestPersonalVoiceAuthorization()
            BCILog.voice.notice("personal voice authorization: \(granted ? "granted" : "not granted", privacy: .public)")
        }
        // Voice auto-selects the best voice (Personal → Premium/Enhanced → compact);
        // the profile's voiceIdentifier, else NEURALCOMPOSE_VOICE_ID, pins one.
        let voiceIdentifier = voiceProfile?.voiceIdentifier
            ?? ProcessInfo.processInfo.environment["NEURALCOMPOSE_VOICE_ID"]
        let voiceOutput = VoiceOutputFactory.live(voiceIdentifier: voiceIdentifier)
        BCILog.voice.notice("voice output resolved: \(voiceOutput.synthesizer.voiceIdentifier, privacy: .public)")
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
                modelDirectory: ModelLocator.url(for: "BGE-small-en-v1.5")
            )
            sentenceEmbedderBackend = "coreml"
        } catch {
            sentenceEmbedder = DeterministicSentenceEmbedder()
            sentenceEmbedderBackend = "stub"
            // Surface *why* we stubbed. Without this the only signal is
            // `embedder-stub` in health.json with no cause — which is exactly how
            // a missing model dir (Models/* is gitignored) or a load-time
            // .mlpackage compile failure stays a mystery. The banner still just
            // says "stub"; this line is for the log.
            BCILog.embedding.notice("CoreML sentence embedder unavailable, using stub: \(error.localizedDescription, privacy: .public)")
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
        let stateStride = max(windowingConfig.strideSeconds, 0.001)
        let stateWindowCapacity = max(1, Int((5.0 / stateStride).rounded(.up)))
        let jepaTransitionCapture = TransitionCaptureManager(
            eegBuffer: JEPASpectralStateRingBuffer(capacity: stateWindowCapacity)
        )

        let worldModelDemo = WorldModelDemoFactory.live()
        BCILog.worldModelDemo.notice("world model demo backend: \(worldModelDemo.kind.rawValue, privacy: .public)")

        // Biofeedback egress: off unless the environment says otherwise.
        // Resolved last; it depends on nothing above and nothing above may
        // depend on it (ADR-011: imported only by the app target).
        let biofeedbackConfiguration = BiofeedbackConfiguration.resolve(environment: ProcessInfo.processInfo.environment)
        let biofeedback = await makeBiofeedback(configuration: biofeedbackConfiguration)

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
            sentenceEmbedderKind: sentenceEmbedderBackend,
            spectralEstimatorResolved: spectralEstimator,
            interactionLogger: interactionLogger,
            jepaTransitionCapture: jepaTransitionCapture,
            worldModelDemoResolved: worldModelDemo,
            voiceProfile: voiceProfile,
            biofeedback: biofeedback,
            biofeedbackConfiguration: biofeedbackConfiguration
        )
    }

    /// Builds the egress coordinator for a configuration, or `nil` when no
    /// transport is enabled or every enabled transport failed to open. Each
    /// transport logs its destination at `.notice` so a session log always
    /// records where features were sent (ADR-011 §3).
    static func makeBiofeedback(configuration: BiofeedbackConfiguration) async -> BiofeedbackCoordinator? {
        guard configuration.isEnabled else { return nil }
        var sinks: [any BiofeedbackSink] = []

        if let osc = configuration.osc {
            let sender = OSCUDPSender(host: osc.host, port: osc.port)
            await sender.start()
            sinks.append(sender)
            BCILog.pipeline.notice("biofeedback OSC egress -> \(osc.endpoint, privacy: .public) (\(osc.isLoopback ? "loopback" : "LAN", privacy: .public))\(configuration.includeRawEEG ? ", raw /muse/eeg ON" : "", privacy: .public)")
        }

        if configuration.midi {
            #if canImport(CoreMIDI)
            do {
                let source = try CoreMIDIVirtualSource()
                sinks.append(source)
                BCILog.pipeline.notice("biofeedback MIDI egress: virtual source \"\(source.name, privacy: .public)\" (in-machine)")
            } catch {
                BCILog.pipeline.error("biofeedback MIDI egress unavailable: \(String(describing: error), privacy: .public)")
            }
            #else
            BCILog.pipeline.error("biofeedback MIDI egress requested but CoreMIDI is unavailable on this platform")
            #endif
        }

        guard !sinks.isEmpty else { return nil }

        var mappings: [BiofeedbackMapping] = []
        if let path = configuration.mappingsPath {
            do {
                mappings = try BiofeedbackConfiguration.loadMappings(at: path)
                BCILog.pipeline.notice("biofeedback mappings: \(mappings.count, privacy: .public) from \(path, privacy: .public)")
            } catch {
                BCILog.pipeline.error("biofeedback mappings not loaded from \(path, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }

        let options = BiofeedbackCoordinator.Options(
            mirror: MindMonitorMirror(perChannel: configuration.perChannel),
            includeRawEEG: configuration.includeRawEEG
        )
        return BiofeedbackCoordinator(
            sink: sinks.count == 1 ? sinks[0] : CompositeBiofeedbackSink(sinks),
            mappings: mappings,
            options: options
        )
    }

    private static func profileFromEnvironment() -> MuseBoardProfile {
        let env = ProcessInfo.processInfo.environment
        let defaultProfile = (NSClassFromString("XCTestCase") == nil && bci_bridge_is_available())
            ? "muses"
            : "synthetic"
        let raw = env["NEURALCOMPOSE_BOARD_PROFILE"] ?? defaultProfile
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
