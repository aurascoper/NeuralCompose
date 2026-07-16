import Foundation

/// The canonical evidence artifact this tool produces — raw per-candidate,
/// per-prompt generations plus the metrics that have a reliable automatic
/// score (latency, throughput, verbosity, meaning-preservation for
/// rewrite-shaped prompts). Deliberately does NOT attempt to auto-score
/// instruction-following, grammar, hallucination, or "added commentary" —
/// those are exactly the dimensions a human scores from the companion
/// `scoring-template.csv`, not something this tool fabricates a heuristic
/// for. Same "raw evidence, derived analysis lives elsewhere" split
/// `SemanticEvalResult` already establishes.
struct GenerationEvalResult: Encodable {
    let schemaVersion: Int
    let provenance: Provenance
    let candidates: [CandidateResult]

    struct Provenance: Encodable {
        let gitCommit: String
        let device: String
        let macOSVersion: String
        let candidatesFixtureVersion: Int
        let promptsFixtureVersion: Int

        enum CodingKeys: String, CodingKey {
            case gitCommit = "git_commit"
            case device
            case macOSVersion = "macos_version"
            case candidatesFixtureVersion = "candidates_fixture_version"
            case promptsFixtureVersion = "prompts_fixture_version"
        }
    }

    /// One entry per fixture candidate, present or not. `status` is
    /// `"evaluated"` or `"skipped: not downloaded"` — a skipped candidate's
    /// load/RSS fields are `nil` and `prompts` is empty, rather than the
    /// entry being omitted entirely, so a downstream reader always sees
    /// every fixture candidate accounted for.
    struct CandidateResult: Encodable {
        let name: String
        let directory: String
        let status: String
        let modelIdentifier: String?
        let coldLoadTime: TimeInterval?
        let warmLoadTime: TimeInterval?
        let peakRSSMB: Double?
        let prompts: [PromptResult]

        enum CodingKeys: String, CodingKey {
            case name, directory, status
            case modelIdentifier = "model_identifier"
            case coldLoadTime = "cold_load_time"
            case warmLoadTime = "warm_load_time"
            case peakRSSMB = "peak_rss_mb"
            case prompts
        }
    }

    struct PromptResult: Encodable {
        let promptID: String
        let category: String
        let firstTokenLatency: TimeInterval
        let generateTime: TimeInterval
        let tokensPerSecond: Double
        let generatedText: String
        /// `output word count / input word count` — a cheap proxy for
        /// verbosity; not a claim about quality on its own.
        let wordCountRatio: Double
        /// `nil` for `instruction-following` prompts — see
        /// `rewriteShapedCategories` in `GenerationEvalConfig.swift`.
        let meaningPreservationCosine: Double?
        /// `"eos"` or `"maxTokens"` — whether the model stopped on its own
        /// end-of-turn token or ran to the generation cap.
        let stopReason: String
        /// Words generated per second — distinct from `tokensPerSecond`
        /// (sub-word BPE tokens) because the token-to-word ratio varies by
        /// tokenizer and output.
        let wordsPerSecond: Double
        /// Longest short-period n-gram loop period (1-3) found in the
        /// output. `0` means no loop detected. See
        /// `MLXNextWordPredictor.maxRepeatedNGram`.
        let decoderLoopPeriod: Int
        /// How many times the longest loop's n-gram repeated consecutively.
        /// `1` means no loop.
        let decoderLoopRepeatCount: Int
        /// `true` if the output begins with a substantial prefix of the
        /// prompt text — a known echo failure mode.
        let promptEchoDetected: Bool

        enum CodingKeys: String, CodingKey {
            case promptID = "prompt_id"
            case category
            case firstTokenLatency = "first_token_latency"
            case generateTime = "generate_time"
            case tokensPerSecond = "tokens_per_second"
            case generatedText = "generated_text"
            case wordCountRatio = "word_count_ratio"
            case meaningPreservationCosine = "meaning_preservation_cosine"
            case stopReason = "stop_reason"
            case wordsPerSecond = "words_per_second"
            case decoderLoopPeriod = "decoder_loop_period"
            case decoderLoopRepeatCount = "decoder_loop_repeat_count"
            case promptEchoDetected = "prompt_echo_detected"
        }
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case provenance, candidates
    }
}
