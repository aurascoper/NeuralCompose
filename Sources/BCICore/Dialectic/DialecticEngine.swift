import Foundation

/// Result of one `DialecticEngine.refine(_:)` pass over a composed sentence.
/// `synthesis` is the recommended final phrasing; `thesis`/`antithesis` are
/// kept so the UI can show the reasoning, not just the answer.
public struct Refinement: Sendable, Equatable {
    public let original: String
    public let thesis: String
    public let antithesis: String
    public let synthesis: String

    public init(original: String, thesis: String, antithesis: String, synthesis: String) {
        self.original = original
        self.thesis = thesis
        self.antithesis = antithesis
        self.synthesis = synthesis
    }
}

/// Orchestrates three sequential `TextGenerating.generate(...)` calls over a
/// composed sentence — thesis, antithesis, synthesis — and returns a
/// `Refinement`. Pure orchestration: no MLX dependency, `struct` not
/// `actor` (holds no mutable state), fully testable with a fake
/// `TextGenerating`.
///
/// Scope: Level 1 (lexical word-choice) and Level 2 (phrasal rewording)
/// refinement only. See the "Level 3" note at the bottom of this file for
/// the future embedding-space extension — deliberately not designed yet.
///
/// Explicit-trigger only: three sequential decode passes take a few seconds
/// even on a small model, which is fine for a user who presses "Refine" and
/// waits, but far too slow for the carousel's 1.5s tick or per-word commits.
/// Callers must never invoke `refine(_:)` from those hot paths.
public struct DialecticEngine: Sendable {

    public struct Config: Sendable {
        public var maxTokens: Int
        public var temperature: Double
        public init(maxTokens: Int = 120, temperature: Double = 0.7) {
            self.maxTokens = maxTokens
            self.temperature = temperature
        }
    }

    private let generator: any TextGenerating
    private let metrics: any MetricsRecording
    private let config: Config

    public init(
        generator: any TextGenerating,
        metrics: any MetricsRecording = NullMetricsRecorder(),
        config: Config = .init()
    ) {
        self.generator = generator
        self.metrics = metrics
        self.config = config
    }

    /// Runs thesis → antithesis → synthesis in sequence. Checks
    /// cancellation between passes (not just inside each `generate` call)
    /// so a cancelled `Task` bails before starting wasted work.
    public func refine(_ composed: String, cancellationID: UUID = UUID()) async throws -> Refinement {
        try Task.checkCancellation()
        let thesis = try await generator.generate(
            prompt: Self.thesisPrompt(for: composed),
            maxTokens: config.maxTokens, temperature: config.temperature,
            cancellationID: cancellationID
        )

        try Task.checkCancellation()
        let antithesis = try await generator.generate(
            prompt: Self.antithesisPrompt(for: composed, thesis: thesis),
            maxTokens: config.maxTokens, temperature: config.temperature,
            cancellationID: cancellationID
        )

        try Task.checkCancellation()
        let synthesis = try await generator.generate(
            prompt: Self.synthesisPrompt(for: composed, thesis: thesis, antithesis: antithesis),
            maxTokens: config.maxTokens, temperature: config.temperature,
            cancellationID: cancellationID
        )

        return Refinement(original: composed, thesis: thesis, antithesis: antithesis, synthesis: synthesis)
    }

    // MARK: - Prompt templates (Level 1-2 only; see Level 3 note below)

    static func thesisPrompt(for text: String) -> String {
        """
        You are helping someone who communicates using an assistive brain-computer \
        typing device rephrase a message they just composed one word at a time. \
        Their raw composed text often has minimal punctuation and simple word choices.

        Composed message: "\(text)"

        Task: Rewrite this as the clearest, most natural-sounding version of what they \
        most likely mean. Keep the same intent, meaning, and level of formality. Prefer \
        their most probable word choices; do not invent new information or add facts \
        that are not implied by the text. Output ONLY the rewritten sentence, nothing else.
        """
    }

    static func antithesisPrompt(for text: String, thesis: String) -> String {
        """
        You are helping refine an assistive-communication message.

        Composed message: "\(text)"

        A first rephrasing was already proposed:
        Rephrasing A: "\(thesis)"

        Task: Propose a second, genuinely different rephrasing of the ORIGINAL composed \
        message — one that takes a distinct interpretation of tone, urgency, or emphasis \
        (for example: more direct vs. more polite, a statement vs. a request, or \
        emphasizing a different part of the message) rather than a synonym-swapped \
        restatement of Rephrasing A. Go back to the original composed message and \
        consider what else it could plausibly mean or how else it could be phrased. \
        Output ONLY the alternative rephrasing, nothing else.
        """
    }

    static func synthesisPrompt(for text: String, thesis: String, antithesis: String) -> String {
        """
        You are finalizing a message for someone using an assistive brain-computer \
        typing device.

        Composed message: "\(text)"

        Two candidate rephrasings were proposed:
        Rephrasing A: "\(thesis)"
        Rephrasing B: "\(antithesis)"

        Task: Choose or blend the single best final phrasing that most faithfully and \
        clearly expresses the ORIGINAL composed message. Prefer whichever candidate (or \
        combination) best preserves the person's most likely intent, is natural to say \
        aloud, and is no longer or more complex than necessary. Output ONLY the final \
        sentence, nothing else — no explanation, no labels, no quotation marks.
        """
    }
}

// MARK: - Level 3 (future, not built now)
//
// Level 3 would let refinement navigate in embedding space rather than only
// through word-level LLM rewrites: e.g. project the composed sentence and
// candidate rephrasings into a shared embedding via a Core ML sentence
// embedder (`BCIEmbedding`, not yet built — currently "banked"), then offer
// refinements along interpretable directions (more formal/informal, more
// urgent/calm) discovered in that space, or cluster multiple synthesis
// candidates by semantic proximity instead of generating exactly one. This
// depends on `BCIEmbedding` existing and on `EmbeddingProjecting`/
// `TokenEmbeddingProviding` (today diagnostic-only, logits-based, explicitly
// documented as not a real semantic embedding) being replaced by an actual
// sentence-embedding backend. No API for this is designed here — flagging
// the extension point only.
