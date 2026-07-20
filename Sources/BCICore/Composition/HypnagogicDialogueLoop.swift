import Foundation

/// Experimental, opt-in hypnagogic dialogue loop. On each turn it LISTENS for a
/// short spoken utterance (on-device STT), sends the transcript to a
/// `TextGenerating` engine constrained to soft, ≤2-sentence "mirror" replies,
/// and SPEAKS the reply with hypnagogic prosody — then repeats. On a silent turn
/// it speaks a pre-programmed induction cue instead of calling the model.
///
/// Honest scope (read before extending):
///  - **MANUAL trigger only.** It is NOT wired to any sleep-stage / N1 detector.
///    The S-3 classifier is synthetic-only and unvalidated on real data (see
///    `decision_registry.md` entry 7 / `SLEEP_CYCLE_DESIGN.md`); firing this on
///    an unreliable N1 signal is out of scope.
///  - The generator MAY be a network/cloud model — the sole runtime exception
///    to "No network at runtime" (`decision_registry.md` entry 8). STT stays
///    on-device, so only *text* — never audio — can leave the machine, and
///    nothing is persisted. The opt-in flag + privacy banner make it visible
///    while active.
///  - Engineering scaffolding, **NOT** a validated intervention. Any efficacy
///    claim requires the D8 pre-registration ("non-negotiable").
///
/// Pure orchestration over injected seams (`HypnagogicListening`,
/// `TextGenerating`, `SpeechSynthesizing`), fully testable with spies; it never
/// links AVFoundation, MLX, or the CLI itself. Mic and speaker are used in
/// strict alternation (listen → speak → listen), so the mic is never hot during
/// playback — no acoustic feedback path, no explicit mute needed.
public actor HypnagogicDialogueLoop {

    public struct Config: Sendable {
        /// How long each listen turn waits for an utterance before treating the
        /// turn as silent.
        public var listenTimeout: TimeInterval
        /// Pause between a spoken reply and the next listen turn.
        public var interTurnDelayNanos: UInt64
        public var maxTokens: Int
        public var temperature: Double
        public var prosody: SpeechProsody
        /// Rotating soft cues spoken on a silent turn (no model call).
        public var silenceCues: [String]

        public init(
            listenTimeout: TimeInterval = 15,
            interTurnDelayNanos: UInt64 = 3_000_000_000,
            maxTokens: Int = 60,
            temperature: Double = 0.6,
            prosody: SpeechProsody = .hypnagogic,
            silenceCues: [String] = HypnagogicDialogueLoop.defaultSilenceCues
        ) {
            self.listenTimeout = listenTimeout
            self.interTurnDelayNanos = interTurnDelayNanos
            self.maxTokens = maxTokens
            self.temperature = temperature
            self.prosody = prosody
            self.silenceCues = silenceCues
        }
    }

    public static let defaultSilenceCues = [
        "Drifting, softly, deeper.",
        "Let the shapes dissolve and float away.",
        "Sinking, warm and slow.",
        "The quiet carries you down.",
    ]

    private let listener: any HypnagogicListening
    private let generator: any TextGenerating
    private let speaker: any SpeechSynthesizing
    private let config: Config

    private var loopTask: Task<Void, Never>?
    private var silenceIndex = 0
    public private(set) var isRunning = false

    public init(
        listener: any HypnagogicListening,
        generator: any TextGenerating,
        speaker: any SpeechSynthesizing,
        config: Config = .init()
    ) {
        self.listener = listener
        self.generator = generator
        self.speaker = speaker
        self.config = config
    }

    /// Starts the loop if not already running. Idempotent.
    public func start() {
        guard loopTask == nil else { return }
        isRunning = true
        loopTask = Task { [weak self] in
            await self?.run()
        }
    }

    /// Cancels the loop, aborts any in-flight listen, and interrupts speech.
    /// Safe to call when idle. Reentrant at every `await`, so it takes effect
    /// even while `run()` is suspended in listen/generate/speak.
    public func stop() async {
        loopTask?.cancel()
        loopTask = nil
        isRunning = false
        await listener.cancel()
        await speaker.stopSpeaking()
    }

    private func run() async {
        while !Task.isCancelled {
            do {
                let heard = try await listener.listen(timeout: config.listenTimeout)
                try Task.checkCancellation()

                let reply: String
                if let transcript = heard?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !transcript.isEmpty {
                    reply = try await generator.generate(
                        prompt: transcript,
                        maxTokens: config.maxTokens,
                        temperature: config.temperature,
                        cancellationID: UUID()
                    )
                } else {
                    // Silent turn — no model call; speak a rotating induction cue.
                    reply = nextSilenceCue()
                }

                try Task.checkCancellation()
                try await speakChunks(reply)
            } catch is CancellationError {
                return
            } catch {
                // A listen/generate/speak failure (incl. BCIError.cancelled from
                // stopSpeaking) — exit if cancelled, else fall through to the
                // delay rather than hot-spinning on a persistent error.
                if Task.isCancelled { return }
            }

            do {
                try await Task.sleep(nanoseconds: config.interTurnDelayNanos)
            } catch {
                return
            }
        }
    }

    /// Speaks a reply as soft micro-phrases (split on sentence/clause
    /// punctuation), each with hypnagogic prosody. The mic is already closed
    /// (listen has returned), so there is no feedback path.
    private func speakChunks(_ text: String) async throws {
        for chunk in Self.chunk(text) {
            try Task.checkCancellation()
            try await speaker.speak(chunk, prosody: config.prosody)
        }
    }

    private func nextSilenceCue() -> String {
        guard !config.silenceCues.isEmpty else { return "" }
        let cue = config.silenceCues[silenceIndex % config.silenceCues.count]
        silenceIndex += 1
        return cue
    }

    /// Splits text into speakable micro-phrases on `.`, `,`, `;`, `…`, `!`, `?`.
    /// Pure/static so it is unit-testable. Falls back to the whole (trimmed)
    /// text when there is no terminal punctuation.
    public static func chunk(_ text: String) -> [String] {
        var chunks: [String] = []
        var current = ""
        for ch in text {
            current.append(ch)
            if ch == "." || ch == "," || ch == ";" || ch == "…" || ch == "!" || ch == "?" {
                let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { chunks.append(trimmed) }
                current = ""
            }
        }
        let tail = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { chunks.append(tail) }
        if chunks.isEmpty {
            let whole = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return whole.isEmpty ? [] : [whole]
        }
        return chunks
    }
}
