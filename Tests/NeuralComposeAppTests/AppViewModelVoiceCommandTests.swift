import XCTest
@testable import BCICore
@testable import BCIClassifier
@testable import BCIEEG
@testable import BCILLM
@testable import BCIVoice
@testable import NeuralComposeApp

/// Tests for the voice command path through `AppViewModel`:
/// `startCommandListening()`, `stopCommandListening()`,
/// `cancelCommandListening()`, and the `isCommanding` /
/// `commandWarning` state.
///
/// **Seam-based, not integration.** An earlier version of this file
/// constructed the view model with `PredictorFactory.live()`'s
/// default model directory — which, on a machine with a real MLX
/// model dropped into `Models/Qwen2.5-0.5B-Instruct-4bit/` (the
/// exact directory name `PredictorFactory` auto-detects), silently
/// loads real MLX weights and compiles Metal kernels on every single
/// `makeViewModel()` call. Four tests meant four full model loads,
/// which is almost certainly what actually hung the suite — not an
/// actor/MainActor deadlock. Fixed here by pointing
/// `PredictorFactory.live(modelDirectory:)` at a path that can't
/// exist, forcing the stub predictor deterministically regardless of
/// what's on disk.
///
/// The rest of the pipeline is similarly kept cheap and
/// self-contained: `EEGStreamFactory.makeSynthetic()` instead of a
/// real network listener, and a `SpyVoiceCommandRecognizer` in place
/// of `VoiceCommandFactory.live()` so each test controls
/// authorization/recognition outcomes directly instead of depending
/// on the stub's fixed always-reject behavior.
///
/// The dispatcher-routing behavior (recognized command ->
/// `AppCommandDispatcher.perform(_:)`) already has full per-case
/// coverage in `AppCommandDispatcherTests`. This file covers the
/// view-model-level wiring: lifecycle guards, the warning surface,
/// and that `stopCommandListening()` reaches the dispatcher exactly
/// once with the recognized command.
@MainActor
final class AppViewModelVoiceCommandTests: XCTestCase {

    // MARK: - Spies

    /// Records every call and lets each test script the recognizer's
    /// outcome (authorization, start failure, recognition result)
    /// without touching Speech/AVAudioEngine at all.
    private final class SpyVoiceCommandRecognizer: VoiceCommandRecognizing, @unchecked Sendable {
        let isLive = false
        let engineIdentifier = "spy-cmd"

        var authorizationResult = true
        var startCommandError: Error?
        var stopAndRecognizeResult: (AppCommand?, CommandRecognitionResult) = (
            nil,
            CommandRecognitionResult(
                transcript: "", normalized: "", command: nil,
                confidence: 0, rejectionReason: .emptyTranscript
            )
        )
        var stopAndRecognizeError: Error?

        private(set) var callLog: [String] = []

        func requestAuthorization() async -> Bool {
            callLog.append("requestAuthorization")
            return authorizationResult
        }

        func startCommand() async throws {
            callLog.append("startCommand")
            if let startCommandError { throw startCommandError }
        }

        func stopCommand() async throws -> String {
            callLog.append("stopCommand")
            return ""
        }

        func cancelCommand() async {
            callLog.append("cancelCommand")
        }

        func recognizeLastTranscript() async -> (AppCommand?, CommandRecognitionResult) {
            callLog.append("recognizeLastTranscript")
            return stopAndRecognizeResult
        }

        func stopAndRecognize() async throws -> (AppCommand?, CommandRecognitionResult) {
            callLog.append("stopAndRecognize")
            if let stopAndRecognizeError { throw stopAndRecognizeError }
            return stopAndRecognizeResult
        }
    }

    /// Same spy target shape as `AppCommandDispatcherTests`' `SpyTarget`
    /// — records dispatched commands so tests can assert
    /// `stopCommandListening()` reaches the dispatcher exactly once,
    /// without asserting on the real side effects those commands
    /// would otherwise cause.
    private final class SpyDispatchTarget: AppCommandDispatchTarget {
        var pendingWindowOpen: String?
        var pendingTab: PendingTab?
        private(set) var callLog: [String] = []

        func startCalibrationRecording() async { callLog.append("startCalibrationRecording") }
        func stopCalibrationRecording() async { callLog.append("stopCalibrationRecording") }
        func startImaginedSpeechSession() async { callLog.append("startImaginedSpeechSession") }
        func resetComposition() async { callLog.append("resetComposition") }
        func speak() async { callLog.append("speak") }
        func refineComposedText() async { callLog.append("refineComposedText") }
        func startDictation() async { callLog.append("startDictation") }
        func stopDictation() async { callLog.append("stopDictation") }
        func startCommandListening() async { callLog.append("startCommandListening") }
        func stopCommandListening() async { callLog.append("stopCommandListening") }
    }

    // MARK: - Fixture

    private func makeViewModel(recognizer: SpyVoiceCommandRecognizer) async -> AppViewModel {
        let container = AppContainer(
            streamResolved: EEGStreamFactory.makeSynthetic(),
            classifierResolved: ClassifierFactory.live(),
            // A path that can't exist forces the stub predictor
            // deterministically, regardless of what's dropped into
            // Models/ on the machine running the test. See the class
            // doc comment for why this matters.
            predictorResolved: await PredictorFactory.live(
                modelDirectory: URL(fileURLWithPath: "/nonexistent/AppViewModelVoiceCommandTests")
            ),
            voiceOutputResolved: VoiceOutputFactory.live(),
            voiceInputResolved: VoiceInputFactory.live(overrideAvailability: false),
            voiceCommandResolved: VoiceCommandFactory.Resolved(
                recognizer: recognizer, kind: .stub, warning: nil
            ),
            metrics: MetricsCollector(),
            windowingConfig: EEGWindowingConfig(
                windowSeconds: 2.0, strideSeconds: 1.0, sampleRate: 256, channelCount: 4
            )
        )
        return AppViewModel(container: container)
    }

    private func makeDispatcher() -> (AppCommandDispatcher, SpyDispatchTarget) {
        let spy = SpyDispatchTarget()
        return (AppCommandDispatcher(target: spy), spy)
    }

    // MARK: - startCommandListening()

    func testStartCommandListeningWithAuthorizationDeniedSetsWarningAndDoesNotFlipIsCommanding() async {
        let recognizer = SpyVoiceCommandRecognizer()
        recognizer.authorizationResult = false
        let viewModel = await makeViewModel(recognizer: recognizer)

        await viewModel.startCommandListening()

        XCTAssertFalse(viewModel.isCommanding)
        XCTAssertEqual(viewModel.commandWarning, "Microphone/speech access not granted")
        XCTAssertEqual(recognizer.callLog, ["requestAuthorization"], "startCommand should never be attempted without authorization")
    }

    func testStartCommandListeningWhenStartCommandThrowsSetsWarningAndDoesNotFlipIsCommanding() async {
        let recognizer = SpyVoiceCommandRecognizer()
        recognizer.authorizationResult = true
        recognizer.startCommandError = BCIError.speechRecognitionUnavailable(reason: "no mic")
        let viewModel = await makeViewModel(recognizer: recognizer)

        await viewModel.startCommandListening()

        XCTAssertFalse(viewModel.isCommanding)
        XCTAssertEqual(recognizer.callLog, ["requestAuthorization", "startCommand"])
        XCTAssertTrue(
            viewModel.commandWarning?.hasPrefix("Voice commands unavailable:") ?? false,
            "got: \(viewModel.commandWarning ?? "nil")"
        )
    }

    func testStartCommandListeningSucceedsFlipsIsCommanding() async {
        let recognizer = SpyVoiceCommandRecognizer()
        recognizer.authorizationResult = true
        let viewModel = await makeViewModel(recognizer: recognizer)

        await viewModel.startCommandListening()

        XCTAssertTrue(viewModel.isCommanding)
        XCTAssertNil(viewModel.commandWarning)
        XCTAssertEqual(recognizer.callLog, ["requestAuthorization", "startCommand"])
    }

    func testStartCommandListeningGuardsAgainstDoubleStart() async {
        let recognizer = SpyVoiceCommandRecognizer()
        recognizer.authorizationResult = true
        let viewModel = await makeViewModel(recognizer: recognizer)

        await viewModel.startCommandListening()
        XCTAssertTrue(viewModel.isCommanding)
        let logAfterFirstStart = recognizer.callLog

        await viewModel.startCommandListening()

        XCTAssertEqual(
            recognizer.callLog, logAfterFirstStart,
            "second call while already commanding should be a no-op on the recognizer"
        )
    }

    // MARK: - stopCommandListening()

    func testStopCommandListeningIsNoOpWhenNotCommanding() async {
        let recognizer = SpyVoiceCommandRecognizer()
        let viewModel = await makeViewModel(recognizer: recognizer)
        let (dispatcher, dispatchSpy) = makeDispatcher()
        viewModel.commandDispatcher = dispatcher

        await viewModel.stopCommandListening()

        XCTAssertFalse(viewModel.isCommanding)
        XCTAssertNil(viewModel.commandWarning)
        XCTAssertTrue(recognizer.callLog.isEmpty, "recognizer should not be touched when not commanding")
        XCTAssertTrue(dispatchSpy.callLog.isEmpty)
    }

    func testStopCommandListeningDispatchesRecognizedCommandExactlyOnce() async {
        let recognizer = SpyVoiceCommandRecognizer()
        recognizer.authorizationResult = true
        recognizer.stopAndRecognizeResult = (
            .speak,
            CommandRecognitionResult(
                transcript: "speak that", normalized: "speak that",
                command: .speak, confidence: 1.0, rejectionReason: nil
            )
        )
        let viewModel = await makeViewModel(recognizer: recognizer)
        let (dispatcher, dispatchSpy) = makeDispatcher()
        viewModel.commandDispatcher = dispatcher

        await viewModel.startCommandListening()
        await viewModel.stopCommandListening()

        XCTAssertFalse(viewModel.isCommanding)
        XCTAssertNil(viewModel.commandWarning)
        XCTAssertEqual(dispatchSpy.callLog, ["speak"], "dispatcher should be reached exactly once with the recognized command")
    }

    func testStopCommandListeningWithNoMatchSetsWarningAndDoesNotDispatch() async {
        let recognizer = SpyVoiceCommandRecognizer()
        recognizer.authorizationResult = true
        recognizer.stopAndRecognizeResult = (
            nil,
            CommandRecognitionResult(
                transcript: "gibberish", normalized: "gibberish",
                command: nil, confidence: 0.1, rejectionReason: .noMatch
            )
        )
        let viewModel = await makeViewModel(recognizer: recognizer)
        let (dispatcher, dispatchSpy) = makeDispatcher()
        viewModel.commandDispatcher = dispatcher

        await viewModel.startCommandListening()
        await viewModel.stopCommandListening()

        XCTAssertFalse(viewModel.isCommanding)
        XCTAssertEqual(viewModel.commandWarning, "Couldn't recognize that command")
        XCTAssertTrue(dispatchSpy.callLog.isEmpty)
    }

    func testStopCommandListeningWhenRecognizerThrowsSetsWarningAndDoesNotDispatch() async {
        let recognizer = SpyVoiceCommandRecognizer()
        recognizer.authorizationResult = true
        recognizer.stopAndRecognizeError = BCIError.speechRecognitionUnavailable(reason: "engine died")
        let viewModel = await makeViewModel(recognizer: recognizer)
        let (dispatcher, dispatchSpy) = makeDispatcher()
        viewModel.commandDispatcher = dispatcher

        await viewModel.startCommandListening()
        await viewModel.stopCommandListening()

        XCTAssertFalse(viewModel.isCommanding)
        XCTAssertTrue(
            viewModel.commandWarning?.hasPrefix("Voice command failed:") ?? false,
            "got: \(viewModel.commandWarning ?? "nil")"
        )
        XCTAssertTrue(dispatchSpy.callLog.isEmpty)
    }

    func testStopCommandListeningWithRecognizedCommandButNoDispatcherDoesNotCrash() async {
        let recognizer = SpyVoiceCommandRecognizer()
        recognizer.authorizationResult = true
        recognizer.stopAndRecognizeResult = (
            .speak,
            CommandRecognitionResult(
                transcript: "speak that", normalized: "speak that",
                command: .speak, confidence: 1.0, rejectionReason: nil
            )
        )
        let viewModel = await makeViewModel(recognizer: recognizer)
        // commandDispatcher intentionally left nil.

        await viewModel.startCommandListening()
        await viewModel.stopCommandListening()

        XCTAssertFalse(viewModel.isCommanding)
        XCTAssertNil(viewModel.commandWarning, "a recognized command with no dispatcher wired should not surface a warning")
    }

    // MARK: - cancelCommandListening()

    func testCancelCommandListeningIsNoOpWhenNotCommanding() async {
        let recognizer = SpyVoiceCommandRecognizer()
        let viewModel = await makeViewModel(recognizer: recognizer)

        await viewModel.cancelCommandListening()

        XCTAssertFalse(viewModel.isCommanding)
        XCTAssertNil(viewModel.commandWarning)
        XCTAssertTrue(recognizer.callLog.isEmpty)
    }

    func testCancelCommandListeningClearsStateAndCallsCancelCommand() async {
        let recognizer = SpyVoiceCommandRecognizer()
        recognizer.authorizationResult = true
        let viewModel = await makeViewModel(recognizer: recognizer)
        let (dispatcher, dispatchSpy) = makeDispatcher()
        viewModel.commandDispatcher = dispatcher

        await viewModel.startCommandListening()
        XCTAssertTrue(viewModel.isCommanding)

        await viewModel.cancelCommandListening()

        XCTAssertFalse(viewModel.isCommanding)
        XCTAssertNil(viewModel.commandWarning)
        XCTAssertEqual(recognizer.callLog, ["requestAuthorization", "startCommand", "cancelCommand"])
        XCTAssertTrue(dispatchSpy.callLog.isEmpty, "cancel should never reach the dispatcher")
    }
}
