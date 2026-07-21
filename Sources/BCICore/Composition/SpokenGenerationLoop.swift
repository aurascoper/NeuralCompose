import Foundation

/// Experimental, opt-in loop that periodically generates a short piece of text
/// on-device and speaks it aloud, waits, and repeats until stopped.
///
/// Honest scope: the generation parameters it uses come from
/// `GenerationAdaptation`, which is derived from **EEG signal quality
/// (electrode contact / hardware confidence)** — NOT any cognitive-state or
/// "brain reading." No trained model and no MPPI drive this; it is a plain
/// generate→speak cadence. See `SpokenGenerationHonesty` for the user-facing
/// caveats.
///
/// Pure orchestration over injected seams (`TextGenerating`,
/// `SpeechSynthesizing`, an optional `DialecticEngine`, and a closure that
/// yields the current `GenerationAdaptation`), so it is fully testable with
/// spy collaborators and never links MLX or AVFoundation itself. It runs on
/// its own `Task` and only ever awaits those actors — it never touches the
/// EEG/BLE path.
public actor SpokenGenerationLoop {

    public struct Config: Sendable {
        /// Seed continuation text the model extends each cycle. Neutral by
        /// design — never phrased as suggestion/hypnosis or as a claim about
        /// the user's mental state.
        public var seedPrompt: String
        public var maxTokens: Int
        public var interUtteranceDelayNanos: UInt64
        /// When true, route the base generation through `DialecticEngine`
        /// (three extra decode passes) before speaking. Off for the minimal loop.
        public var useDialectic: Bool

        public init(
            seedPrompt: String = SpokenGenerationLoop.defaultSeedPrompt,
            maxTokens: Int = 40,
            interUtteranceDelayNanos: UInt64 = 4_000_000_000,
            useDialectic: Bool = false
        ) {
            self.seedPrompt = seedPrompt
            self.maxTokens = maxTokens
            self.interUtteranceDelayNanos = interUtteranceDelayNanos
            self.useDialectic = useDialectic
        }
    }

    public static let defaultSeedPrompt = "Here is one short, calm sentence to consider."

    private let generator: any TextGenerating
    private let speaker: any SpeechSynthesizing
    private let dialectic: DialecticEngine?
    private let adaptationProvider: @Sendable () async -> GenerationAdaptation
    private let config: Config

    private var loopTask: Task<Void, Never>?
    public private(set) var isRunning = false

    public init(
        generator: any TextGenerating,
        speaker: any SpeechSynthesizing,
        dialectic: DialecticEngine? = nil,
        adaptationProvider: @escaping @Sendable () async -> GenerationAdaptation,
        config: Config = .init()
    ) {
        self.generator = generator
        self.speaker = speaker
        self.dialectic = dialectic
        self.adaptationProvider = adaptationProvider
        self.config = config
    }

    /// Starts the loop if it is not already running. Idempotent.
    public func start() {
        guard loopTask == nil else { return }
        isRunning = true
        loopTask = Task { [weak self] in
            await self?.run()
        }
    }

    /// Cancels the loop and interrupts any in-flight utterance. Safe to call
    /// when idle. Because this actor is reentrant at every `await`, `stop()`
    /// runs even while `run()` is suspended inside `generate`/`speak`/`sleep`.
    public func stop() async {
        loopTask?.cancel()
        loopTask = nil
        isRunning = false
        await speaker.stopSpeaking()
    }

    private func run() async {
        while !Task.isCancelled {
            do {
                let adaptation = await adaptationProvider()
                let cancellationID = UUID()
                // Same soft-priming assembly as TextCompositionController.requestPredictions:
                // prepend the signal-quality styleInstruction ahead of the seed, if any.
                let prompt = adaptation.styleInstruction.isEmpty
                    ? config.seedPrompt
                    : "\(adaptation.styleInstruction)\n\(config.seedPrompt)"

                var text = try await generator.generate(
                    prompt: prompt,
                    maxTokens: config.maxTokens,
                    temperature: adaptation.temperature,
                    cancellationID: cancellationID
                )

                if config.useDialectic, let dialectic {
                    text = try await dialectic.refine(text, cancellationID: cancellationID).synthesis
                }

                try Task.checkCancellation()
                let spoken = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !spoken.isEmpty {
                    // Confidence-wobbled prosody + sentence-boundary pauses, not
                    // one flat prosody-less utterance (the old robotic path):
                    // hedged clauses softer/slower, committed ones firmer.
                    for (phrase, prosody) in ProsodyWobble.plan(spoken) {
                        try await speaker.speak(phrase, prosody: prosody, onWord: nil)
                    }
                }
            } catch is CancellationError {
                return
            } catch {
                // A generation/speech failure — including `BCIError.cancelled`
                // raised by `stopSpeaking()` — lands here. If we were cancelled,
                // exit; otherwise fall through to the delay and retry rather than
                // spinning hot on a persistent error.
                if Task.isCancelled { return }
            }

            do {
                try await Task.sleep(nanoseconds: config.interUtteranceDelayNanos)
            } catch {
                return   // cancelled during the delay
            }
        }
    }
}
