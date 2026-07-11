import AVFoundation
import BCICore
import Foundation
import Speech

/// Push-to-talk speech-to-text: the mic tap and recognition request only
/// exist between `startRecording()` and `stopRecording()`/`cancelRecording()`
/// — there is no continuously-running capture loop anywhere in this type.
public actor PushToTalkSpeechRecognizerService: DictationRecognizing {
    public nonisolated let isLive = true
    public nonisolated let engineIdentifier: String
    public nonisolated var identifier: String { engineIdentifier }

    private let recognizer: SFSpeechRecognizer?
    private let audioEngine = AVAudioEngine()
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var latestTranscript = ""
    private var isRecording = false

    public init(locale: Locale = Locale(identifier: "en-US")) {
        self.recognizer = SFSpeechRecognizer(locale: locale)
        self.engineIdentifier = "sfspeech-\(locale.identifier)"
    }

    public func requestAuthorization() async -> Bool {
        let speechStatus = await withCheckedContinuation { (continuation: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
            SFSpeechRecognizer.requestAuthorization { status in continuation.resume(returning: status) }
        }
        guard speechStatus == .authorized else { return false }
        return await AVCaptureDevice.requestAccess(for: .audio)
    }

    public func startRecording() async throws {
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
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
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

    public func stopRecording() async throws -> String {
        guard isRecording else { return "" }
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        isRecording = false

        // Give the recognizer a brief moment to settle on a final result
        // after audio input ends, before tearing the task down.
        try? await Task.sleep(nanoseconds: 300_000_000)
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil

        let transcript = latestTranscript
        latestTranscript = ""
        return transcript
    }

    public func cancelRecording() async {
        guard isRecording else { return }
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        recognitionTask?.cancel()
        recognitionTask = nil
        recognitionRequest = nil
        latestTranscript = ""
        isRecording = false
    }

    private func updateTranscript(_ text: String) {
        latestTranscript = text
    }
}
