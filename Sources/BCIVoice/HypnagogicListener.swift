import AVFoundation
import BCICore
import Foundation
import Speech

/// On-device, turn-based speech capture for the hypnagogic loop.
///
/// `listen(timeout:)` installs an `AVAudioEngine` tap, feeds a single
/// `SFSpeechAudioBufferRecognitionRequest` (with `requiresOnDeviceRecognition`
/// so raw audio never leaves the machine), and resolves as soon as the
/// recognizer reports a final result — or, if only silence/partials arrive,
/// when `timeout` elapses. Either way the engine and tap are torn down before
/// returning, so the mic is hot only during a listen turn and never during TTS
/// playback (the loop calls `listen` and `speak` in strict alternation, which
/// removes any acoustic feedback path without an explicit mute).
///
/// macOS-correct: permission via `AVCaptureDevice.requestAccess(for: .audio)`,
/// no `AVAudioSession` (iOS-only). Mirrors the tap/recognition pattern in
/// `PushToTalkSpeechRecognizerService`, extended from bounded push-to-talk to a
/// timeout-bounded single-utterance turn.
public actor HypnagogicListener: HypnagogicListening {
    public nonisolated let isLive = true

    private let recognizer: SFSpeechRecognizer?
    private let audioEngine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var continuation: CheckedContinuation<String?, any Error>?
    private var timeoutTask: Task<Void, Never>?
    private var latestPartial = ""

    public init(locale: Locale = Locale(identifier: "en-US")) {
        self.recognizer = SFSpeechRecognizer(locale: locale)
    }

    public func requestAuthorization() async -> Bool {
        let speechStatus = await withCheckedContinuation { (cont: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { status in cont.resume(returning: status) }
        }
        guard speechStatus == .authorized else { return false }
        return await AVCaptureDevice.requestAccess(for: .audio)
    }

    public func listen(timeout: TimeInterval) async throws -> String? {
        guard continuation == nil else {
            throw BCIError.speechRecognitionUnavailable(reason: "a listen turn is already in progress")
        }
        guard let recognizer, recognizer.isAvailable else {
            throw BCIError.speechRecognitionUnavailable(reason: "recognizer unavailable for this locale/Mac")
        }

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition {
            req.requiresOnDeviceRecognition = true
        }
        self.request = req
        self.latestPartial = ""

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            req.append(buffer)
        }
        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            // Never installed a continuation yet — clean up the tap and rethrow.
            inputNode.removeTap(onBus: 0)
            self.request = nil
            throw error
        }

        self.task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            guard let self else { return }
            if let result {
                let text = result.bestTranscription.formattedString
                let isFinal = result.isFinal
                Task { await self.handleResult(text, isFinal: isFinal) }
            } else if error != nil {
                Task { await self.finish(with: nil) }
            }
        }

        self.timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1_000_000_000))
            await self?.handleTimeout()
        }

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String?, any Error>) in
            self.continuation = cont
        }
    }

    public func cancel() async {
        finish(with: nil)
    }

    private func handleResult(_ text: String, isFinal: Bool) {
        latestPartial = text
        if isFinal {
            finish(with: text.isEmpty ? nil : text)
        }
    }

    private func handleTimeout() {
        finish(with: latestPartial.isEmpty ? nil : latestPartial)
    }

    /// Resolves the current listen turn exactly once and tears the mic down.
    private func finish(with transcript: String?) {
        guard let cont = continuation else { return }
        continuation = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        task?.cancel()
        task = nil
        request?.endAudio()
        request = nil
        latestPartial = ""
        cont.resume(returning: transcript)
    }
}
