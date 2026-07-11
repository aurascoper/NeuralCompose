import AVFoundation
import BCICore
import Foundation
import Speech

/// Push-to-talk voice command recognizer: the mic tap and
/// recognition request only exist between `startCommand()` and
/// `stopCommand()`/`cancelCommand()`. There is no continuously-running
/// capture loop anywhere in this type.
///
/// This service owns the **transport** (mic audio → final transcript).
/// The **parser** (transcript → `AppCommand?`) is delegated to an
/// `AppCommandRecognizing` instance passed in at construction. The
/// default parser is `StubCommandRecognizer` (deterministic exact
/// match); a future iteration swaps in `FuzzyCommandRecognizer` for
/// ASR-tolerant matching, then later an embedding-based recognizer.
/// The recognizer's identity is the same `AppCommandRecognizing`
/// protocol either way, so this service's contract is stable.
///
/// **Threading:** `actor`. All state mutations and method calls are
/// serialized. The `recognitionTask` callback runs on an arbitrary
/// thread; it hops to the actor before mutating state.
public actor SpeechCommandRecognizerService: VoiceCommandRecognizing {

    public nonisolated let isLive: Bool = true
    public nonisolated let engineIdentifier: String

    private let recognizer: SFSpeechRecognizer?
    private let audioEngine = AVAudioEngine()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var latestTranscript = ""
    private var isRecording = false

    /// Parser closure for the latest transcript. Captured at
    /// construction so the actor's serialized calls always see the
    /// same parser instance (avoiding the data race of swapping
    /// mid-utterance).
    ///
    /// The signature is `(String, [CommandDescriptor]) -> AppCommand?`
    /// rather than an `AppCommandRecognizing` instance because
    /// `AppCommandRecognizing` lives in `BCICore` and the voice
    /// module is intentionally agnostic of the parser type — the
    /// wiring in `NeuralComposeApp` constructs this closure by
    /// capturing whichever recognizer (stub today, fuzzy later) is
    /// in use. This keeps the dependency direction
    /// `BCIVoice -> BCICore` clean (BCIVoice never depends on
    /// `NeuralComposeApp`).
    private let parser: @Sendable (String, [CommandDescriptor]) -> AppCommand?
    private let vocabulary: [CommandDescriptor]

    public init(
        locale: Locale = Locale(identifier: "en-US"),
        parser: @escaping @Sendable (String, [CommandDescriptor]) -> AppCommand? = { _, _ in nil },
        vocabulary: [CommandDescriptor] = []
    ) {
        self.recognizer = SFSpeechRecognizer(locale: locale)
        self.engineIdentifier = "sfspeech-cmd-\(locale.identifier)"
        self.parser = parser
        self.vocabulary = vocabulary
    }

    // MARK: - Authorization

    public func requestAuthorization() async -> Bool {
        let speechStatus = await withCheckedContinuation { (continuation: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { status in continuation.resume(returning: status) }
        }
        guard speechStatus == .authorized else { return false }
        return await AVCaptureDevice.requestAccess(for: .audio)
    }

    // MARK: - Lifecycle (push-to-talk)

    public func startCommand() async throws {
        guard !isRecording else { return }
        guard let recognizer, recognizer.isAvailable else {
            throw BCIError.speechRecognitionUnavailable(reason: "recognizer unavailable for this locale/Mac")
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = false
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        recognitionRequest = request
        latestTranscript = ""

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { [request] buffer, _ in
            request.append(buffer)
        }
        audioEngine.prepare()
        try audioEngine.start()
        isRecording = true

        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, _ in
            guard let self, let result else { return }
            let text = result.bestTranscription.formattedString
            Task { await self.updateTranscript(text) }
        }
    }

    public func stopCommand() async throws -> String {
        guard isRecording else { return "" }
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        isRecording = false

        // Give the recognizer a brief moment to settle on a final
        // result after audio input ends, before tearing the task
        // down. Mirrors the dictation service's settle behavior.
        try? await Task.sleep(nanoseconds: 300_000_000)
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil

        let transcript = latestTranscript
        latestTranscript = ""
        return transcript
    }

    public func cancelCommand() async {
        guard isRecording else { return }
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        latestTranscript = ""
        isRecording = false
    }

    // MARK: - Recognition

    public func recognizeLastTranscript() async -> (AppCommand?, CommandRecognitionResult) {
        // We don't store the transcript across stop->recognize
        // (we clear it in `stopCommand()` to avoid stale state on
        // a subsequent press). The caller is expected to invoke
        // `recognizeLastTranscript()` immediately after the
        // matching `stopCommand()` with the transcript the stop
        // returned. The wiring in `AppViewModel` is:
        //     let text = try await voiceInput.stopCommand()
        //     let (cmd, result) = await voiceInput.recognize(text)
        //
        // So this method, as specified by the protocol, has no
        // captured state to operate on. To keep the protocol
        // useful (and not require the wiring to thread `text`
        // through), the recognizer's stop command should be
        // called via a convenience method that returns the
        // parsed result directly. See `stopAndRecognize()` below.
        return (nil, CommandRecognitionResult(
            transcript: "",
            normalized: "",
            command: nil,
            confidence: 0.0,
            rejectionReason: .emptyTranscript
        ))
    }

    /// Convenience: stop the recording AND parse the resulting
    /// transcript in one call. This is the path the UI's
    /// `stopCommandListening()` will use — it avoids the
    /// "thread the transcript through" awkwardness of the bare
    /// `recognizeLastTranscript()` API while keeping the protocol
    /// surface for future recognizers that *do* buffer their
    /// own transcript (e.g. a future always-on design that
    /// pre-runs the parser).
    public func stopAndRecognize() async throws -> (AppCommand?, CommandRecognitionResult) {
        let transcript = try await stopCommand()
        let command = parser(transcript, vocabulary)
        let result = CommandRecognitionResult(
            transcript: transcript,
            normalized: transcript
                .lowercased()
                .trimmingCharacters(in: .whitespacesAndNewlines),
            command: command,
            confidence: command == nil ? 0.0 : 1.0,
            rejectionReason: command == nil
                ? (transcript.isEmpty ? .emptyTranscript : .noMatch)
                : nil
        )
        return (command, result)
    }

    // MARK: - Private

    private func updateTranscript(_ text: String) {
        latestTranscript = text
    }
}
