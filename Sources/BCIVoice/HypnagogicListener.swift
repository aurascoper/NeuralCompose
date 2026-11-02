import AVFoundation
import BCICore
import Foundation
import Speech

/// On-device, turn-based speech capture for the hypnagogic loop.
///
/// `listen(timeout:)` installs an `AVAudioEngine` tap and feeds an
/// `SFSpeechAudioBufferRecognitionRequest` (with `requiresOnDeviceRecognition`
/// so raw audio never leaves the machine). `timeout` bounds the wait for speech
/// to *start*; once words arrive, the turn ends when `trailingSilence` passes
/// with no new words (`UtteranceEndpointer`), or at `maxUtterance`. A recognizer
/// `isFinal` on a mid-sentence pause closes a segment and recognition continues
/// on a fresh request, instead of ending the turn there. Either way the engine
/// and tap are torn down before returning, so the mic is hot only during a
/// listen turn and never during TTS playback (the loop calls `listen` and
/// `speak` in strict alternation, which removes any acoustic feedback path
/// without an explicit mute).
///
/// `contextualStrings` biases recognition toward domain terms the default
/// language model mishears (the Oct 13 log has Oklo as "Oak low", samarium as
/// "Samarian").
///
/// macOS-correct: permission via `AVCaptureDevice.requestAccess(for: .audio)`,
/// no `AVAudioSession` (iOS-only). Mirrors the tap/recognition pattern in
/// `PushToTalkSpeechRecognizerService`, extended from bounded push-to-talk to a
/// timeout-bounded single-utterance turn.
public actor HypnagogicListener: HypnagogicListening {
    public nonisolated let isLive = true
    /// Seconds without a new word before a turn ends.
    public static let defaultTrailingSilence: TimeInterval = 1.8
    /// Backstop on one turn's length once speech has started.
    public static let maxUtterance: TimeInterval = 60

    private let recognizer: SFSpeechRecognizer?
    private let contextualStrings: [String]
    private let trailingSilence: TimeInterval
    private let audioEngine = AVAudioEngine()
    private let tapTarget = TapTarget()
    private var task: SFSpeechRecognitionTask?
    /// Tags recognition callbacks so a finished segment's late results are ignored.
    private var segment = 0
    private var endpointer: UtteranceEndpointer
    private var continuation: CheckedContinuation<String?, any Error>?
    private var timeoutTask: Task<Void, Never>?
    private var silenceTask: Task<Void, Never>?

    public init(
        locale: Locale = Locale(identifier: "en-US"),
        contextualStrings: [String] = [],
        trailingSilence: TimeInterval = defaultTrailingSilence
    ) {
        self.recognizer = SFSpeechRecognizer(locale: locale)
        self.contextualStrings = contextualStrings
        self.trailingSilence = trailingSilence
        self.endpointer = UtteranceEndpointer(trailingSilence: trailingSilence)
    }

    /// One segment's recognition request. Pure, so the configuration is testable
    /// without a microphone.
    static func makeRequest(contextualStrings: [String], onDevice: Bool) -> SFSpeechAudioBufferRecognitionRequest {
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        req.requiresOnDeviceRecognition = onDevice
        req.contextualStrings = contextualStrings
        return req
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

        endpointer = UtteranceEndpointer(trailingSilence: trailingSilence)
        let req = Self.makeRequest(contextualStrings: contextualStrings,
                                   onDevice: recognizer.supportsOnDeviceRecognition)
        tapTarget.set(req)

        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        let target = tapTarget
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            target.append(buffer)
        }
        audioEngine.prepare()
        do {
            try audioEngine.start()
        } catch {
            // Never installed a continuation yet — clean up the tap and rethrow.
            inputNode.removeTap(onBus: 0)
            tapTarget.set(nil)
            throw error
        }

        beginRecognition(with: req, using: recognizer)

        self.timeoutTask = Task { [weak self] in
            // A cancelled sleep returns at once; finish() cancels this task.
            try? await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.handleTimeout()
            try? await Task.sleep(nanoseconds: UInt64(max(0, Self.maxUtterance - timeout) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.handleMaxUtterance()
        }
        self.silenceTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard let self else { return }
                await self.checkSilence()
            }
        }

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String?, any Error>) in
            self.continuation = cont
        }
    }

    public func cancel() async {
        finish(with: nil)
    }

    private func beginRecognition(with req: SFSpeechAudioBufferRecognitionRequest, using recognizer: SFSpeechRecognizer) {
        segment += 1
        let tag = segment
        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            guard let self else { return }
            if let result {
                let text = result.bestTranscription.formattedString
                let isFinal = result.isFinal
                Task { await self.handleResult(text, isFinal: isFinal, segment: tag) }
            } else if error != nil {
                Task { await self.handleError(segment: tag) }
            }
        }
    }

    private func handleResult(_ text: String, isFinal: Bool, segment tag: Int) {
        guard continuation != nil, tag == segment else { return }
        endpointer.observe(text, isFinal: isFinal, at: Date())
        if isFinal { startNextSegment() }
    }

    /// The recognizer finalized a segment on a pause; keep listening on a fresh
    /// request fed by the same tap.
    private func startNextSegment() {
        guard let recognizer else { return finish(with: endpointer.transcript) }
        tapTarget.current?.endAudio()
        let next = Self.makeRequest(contextualStrings: contextualStrings,
                                    onDevice: recognizer.supportsOnDeviceRecognition)
        tapTarget.set(next)
        beginRecognition(with: next, using: recognizer)
    }

    private func handleError(segment tag: Int) {
        guard tag == segment else { return }
        // Keep what was heard: an error after some words used to drop the turn.
        finish(with: endpointer.transcript)
    }

    private func checkSilence() {
        if endpointer.shouldFinish(at: Date()) { finish(with: endpointer.transcript) }
    }

    /// The wait for speech is over. Silence ends the turn; if words are still
    /// arriving, the silence check ends it.
    private func handleTimeout() {
        if endpointer.transcript == nil { finish(with: nil) }
    }

    private func handleMaxUtterance() {
        finish(with: endpointer.transcript)
    }

    /// Resolves the current listen turn exactly once and tears the mic down.
    private func finish(with transcript: String?) {
        guard let cont = continuation else { return }
        continuation = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        silenceTask?.cancel()
        silenceTask = nil
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        segment += 1
        task?.cancel()
        task = nil
        tapTarget.current?.endAudio()
        tapTarget.set(nil)
        endpointer = UtteranceEndpointer(trailingSilence: trailingSilence)
        cont.resume(returning: transcript)
    }
}

/// The request the mic tap appends to, swapped when a segment closes mid-turn.
/// The tap runs on the audio thread and the request type is not `Sendable`, so
/// every access goes through the lock.
private final class TapTarget: @unchecked Sendable {
    private let lock = NSLock()
    private var request: SFSpeechAudioBufferRecognitionRequest?

    var current: SFSpeechAudioBufferRecognitionRequest? { lock.withLock { request } }
    func set(_ request: SFSpeechAudioBufferRecognitionRequest?) { lock.withLock { self.request = request } }
    func append(_ buffer: AVAudioPCMBuffer) { lock.withLock { request?.append(buffer) } }
}
