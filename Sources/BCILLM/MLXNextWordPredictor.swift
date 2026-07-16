import Foundation
import BCICore

#if canImport(MLX) && canImport(MLXLLM) && canImport(MLXLMCommon)
import MLX
import MLXLLM
import MLXLMCommon
import Tokenizers
#endif

/// Generation output plus the timing/throughput `GenerateResult` already
/// computes — `generate()` (the `TextGenerating` conformance) discards
/// everything but `text`; `MLXInitProbe` and `GenerationEval` want the
/// rest. Declared unconditionally (not gated by `canImport(MLX)`) since the
/// non-MLX `#else` build of `generateDetailed` still needs a return type.
/// `public`, not `internal`: `GenerationEval` (a separate executable
/// target) calls `generateDetailed` directly to reuse one already-loaded
/// predictor across many prompts, rather than reloading per prompt the way
/// `MLXInitProbe.run` does.
public struct GenerationMetrics: Sendable {
    public let text: String
    public let promptTime: TimeInterval
    public let generateTime: TimeInterval
    public let tokensPerSecond: Double
    /// `"eos"` if the decode loop stopped by emitting an end-of-turn token,
    /// `"maxTokens"` if it ran to the generation cap. Determined by
    /// comparing `result.tokens.count` to the requested `maxTokens` —
    /// `MLXLMCommon.generate` doesn't surface a structured stop reason.
    public let stopReason: String
    /// Words generated per second — `wordCount(text) / generateTime`.
    /// Distinct from `tokensPerSecond` (sub-word BPE tokens) because the
    /// ratio of tokens to words varies by tokenizer and output language.
    public let wordsPerSecond: Double
    /// Longest short-period n-gram loop found in the output (period 1-3).
    /// `period = 0, repeatCount = 1` means no loop detected. See
    /// `maxRepeatedNGram` below.
    public let decoderLoopPeriod: Int
    public let decoderLoopRepeatCount: Int
    /// `true` if the generated text begins with a substantial prefix of the
    /// prompt — a known failure mode where the model echoes input instead of
    /// producing a response.
    public let promptEchoDetected: Bool

    public init(
        text: String,
        promptTime: TimeInterval,
        generateTime: TimeInterval,
        tokensPerSecond: Double,
        stopReason: String = "unknown",
        wordsPerSecond: Double = 0,
        decoderLoopPeriod: Int = 0,
        decoderLoopRepeatCount: Int = 1,
        promptEchoDetected: Bool = false
    ) {
        self.text = text
        self.promptTime = promptTime
        self.generateTime = generateTime
        self.tokensPerSecond = tokensPerSecond
        self.stopReason = stopReason
        self.wordsPerSecond = wordsPerSecond
        self.decoderLoopPeriod = decoderLoopPeriod
        self.decoderLoopRepeatCount = decoderLoopRepeatCount
        self.promptEchoDetected = promptEchoDetected
    }
}

/// MLX-Swift-backed next-word predictor.
///
/// Loads an MLX-converted causal LM from a local directory and serves
/// top-K next-word candidates via a single forward pass per call. Word
/// boundaries are detected by the BPE convention: a token whose decoded
/// text starts with a space is a complete word start.
///
/// Threading: actor. Forward passes are serialized by the underlying
/// `ModelContainer` — running two on the Apple GPU at once just thrashes.
public actor MLXNextWordPredictor: NextWordPredicting, TokenEmbeddingProviding, TextGenerating {

    public nonisolated let isLive: Bool = true
    public nonisolated let modelIdentifier: String
    public nonisolated let configuration: GenerationConfiguration

    #if canImport(MLX) && canImport(MLXLLM) && canImport(MLXLMCommon)
    private let container: ModelContainer
    #endif

    public init(
        modelDirectory: URL,
        configuration: GenerationConfiguration = .qwen
    ) async throws {
        guard FileManager.default.fileExists(atPath: modelDirectory.path) else {
            throw BCIError.predictorWeightsMissing(path: modelDirectory.path)
        }
        self.modelIdentifier = modelDirectory.lastPathComponent
        self.configuration = configuration

        #if canImport(MLX) && canImport(MLXLLM) && canImport(MLXLMCommon)
        // Registering the family's end-of-turn token as an extra EOS
        // candidate only matters when the decode loop's own
        // `additionalEOSTokenIds` lookup (`Evaluate.swift`) can resolve it via
        // `tokenizer.convertTokenToId`. Harmless no-op for any other model
        // family that happens to load here (unknown token strings are just
        // filtered out, not an error).
        let modelConfiguration = ModelConfiguration(
            directory: modelDirectory, extraEOSTokens: configuration.extraEOSTokens
        )
        do {
            self.container = try await LLMModelFactory.shared.loadContainer(
                configuration: modelConfiguration
            )
        } catch {
            throw BCIError.predictorInitFailed(reason: error.localizedDescription)
        }
        #else
        throw BCIError.predictorInitFailed(reason: "MLX modules not importable")
        #endif
    }

    public func predictNextWords(
        context: String,
        maxCandidates: Int,
        temperature: Double,
        cancellationID: UUID
    ) async throws -> [PredictedWord] {
        try Task.checkCancellation()

        #if canImport(MLX) && canImport(MLXLLM) && canImport(MLXLMCommon)
        let cap = max(1, maxCandidates)
        let temp = Float(max(temperature, 0.0001))
        let prompt = context.isEmpty ? " " : context

        return await container.perform { (ctx: ModelContext) -> [PredictedWord] in
            let tokenIds = ctx.tokenizer.encode(text: prompt)
            guard !tokenIds.isEmpty else { return [] }

            let inputs = MLXArray(tokenIds.map { Int32($0) })[.newAxis]
            let logits = ctx.model(inputs, cache: nil)
            let lastLogits = (logits[0..., -1, 0...] / temp).squeezed()
            eval(lastLogits)

            let raw = lastLogits.asArray(Float.self)
            let candidatePool = min(raw.count, max(64, cap * 8))
            let indexed = raw.enumerated()
                .sorted(by: { $0.element > $1.element })
                .prefix(candidatePool)

            let maxLogit = indexed.first?.element ?? 0
            let exps = indexed.map { Double(exp($0.element - maxLogit)) }
            let sumExp = exps.reduce(0, +)
            guard sumExp > 0 else { return [] }

            var results: [PredictedWord] = []
            results.reserveCapacity(cap)
            for (i, item) in indexed.enumerated() {
                let decoded = ctx.tokenizer.decode(tokens: [item.offset])
                guard Self.isWordStart(decoded) else { continue }
                let prob = Float(exps[i] / sumExp)
                results.append(PredictedWord(text: decoded, probability: prob))
                if results.count >= cap { break }
            }
            return results
        }
        #else
        throw BCIError.predictorInferenceFailed(reason: "MLX modules not importable")
        #endif
    }

    /// Returns the last-token logits from a forward pass over `text` as a
    /// plain `[Float]` — see `TokenEmbeddingProviding` for why this is a
    /// logit vector rather than a pre-projection hidden state. Diagnostic
    /// use only (e.g. the 3D workspace visualizer); not part of the
    /// carousel/prediction path.
    public func embedding(for text: String) async throws -> [Float] {
        try Task.checkCancellation()

        #if canImport(MLX) && canImport(MLXLLM) && canImport(MLXLMCommon)
        let prompt = text.isEmpty ? " " : text

        return await container.perform { (ctx: ModelContext) -> [Float] in
            let tokenIds = ctx.tokenizer.encode(text: prompt)
            guard !tokenIds.isEmpty else { return [] }

            let inputs = MLXArray(tokenIds.map { Int32($0) })[.newAxis]
            let logits = ctx.model(inputs, cache: nil)
            let lastLogits = logits[0..., -1, 0...].squeezed()
            eval(lastLogits)
            return lastLogits.asArray(Float.self)
        }
        #else
        throw BCIError.predictorInferenceFailed(reason: "MLX modules not importable")
        #endif
    }

    // MARK: - TextGenerating

    /// Free-form generation via the vendored `MLXLMCommon.generate(...)`
    /// (an autoregressive decode loop) rather than `predictNextWords`'s
    /// single forward pass. Reuses this actor's already-loaded `container`
    /// — no second model load, consistent with the Package.swift
    /// "single MLX runtime" isolation rule.
    ///
    /// Prompt framing prefers the tokenizer's own chat template
    /// (`Tokenizer.hasChatTemplate`/`applyChatTemplate(messages:)`) over a
    /// hand-rolled format — see `tokenIDs(for:tokenizer:)` below. An earlier
    /// version of this method avoided `applyChatTemplate` entirely because
    /// its `[String: Any]` `Message` type isn't `Sendable`; that turned out
    /// to be the wrong conclusion; `ModelContainer.perform`'s closure only
    /// requires *itself* to be `@Sendable`
    /// (`MLXLMCommon/ModelContainer.swift:63`), and a `[Message]` array
    /// built and consumed entirely inside that closure never crosses an
    /// isolation boundary, so it never needs to be `Sendable`. Skipping chat
    /// framing was also empirically wrong: without it, an instruct model has
    /// little signal to emit its real end-of-turn token, and can drift into
    /// a repetitive decode loop instead of stopping cleanly — see
    /// `MLXGenerationRegressionTests` for the repro this fixes.
    public func generate(
        prompt: String,
        maxTokens: Int,
        temperature: Double,
        cancellationID: UUID
    ) async throws -> String {
        try await generateDetailed(
            prompt: prompt, maxTokens: maxTokens, temperature: temperature,
            cancellationID: cancellationID
        ).text
    }

    #if canImport(MLX) && canImport(MLXLLM) && canImport(MLXLMCommon)
    /// Same generation as `generate`, but keeps the timing/throughput
    /// fields `GenerateResult` already computes (`promptTime`,
    /// `generateTime`, `tokensPerSecond`) instead of discarding them after
    /// extracting `.output`. `generate` (the `TextGenerating` conformance
    /// `DialecticEngine` calls) delegates to this; `MLXInitProbe` and
    /// `GenerationEval` are the other callers, for probe/benchmark metrics
    /// — `public` so `GenerationEval` (a separate executable target) can
    /// call it directly against an already-loaded predictor.
    public func generateDetailed(
        prompt: String,
        maxTokens: Int,
        temperature: Double,
        cancellationID: UUID
    ) async throws -> GenerationMetrics {
        try Task.checkCancellation()

        let text = prompt.isEmpty ? " " : prompt
        let params = GenerateParameters(
            maxTokens: maxTokens,
            temperature: Float(max(temperature, 0.0001)),
            repetitionPenalty: configuration.repetitionPenalty
        )

        return try await container.perform { (ctx: ModelContext) throws -> GenerationMetrics in
            let tokenIds = try Self.tokenIDs(for: text, tokenizer: ctx.tokenizer)
            guard !tokenIds.isEmpty else {
                return GenerationMetrics(text: "", promptTime: 0, generateTime: 0, tokensPerSecond: 0)
            }
            let input = LMInput(tokens: MLXArray(tokenIds))
            let result: GenerateResult = try MLXLMCommon.generate(
                input: input, parameters: params, context: ctx
            ) { _ in .more }
            Self.logGenerationDiagnostics(result: result, maxTokens: maxTokens)

            let trimmedOutput = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            let stoppedAtCap = result.tokens.count >= maxTokens
            let stopReason = stoppedAtCap ? "maxTokens" : "eos"
            let wordCount = trimmedOutput.split(whereSeparator: { $0.isWhitespace }).count
            let wps = result.generateTime > 0
                ? Double(wordCount) / result.generateTime
                : 0
            let (loopPeriod, loopRepeatCount) = Self.maxRepeatedNGram(in: result.output)
            let echoDetected = Self.detectPromptEcho(prompt: text, output: trimmedOutput)

            return GenerationMetrics(
                text: trimmedOutput,
                promptTime: result.promptTime,
                generateTime: result.generateTime,
                tokensPerSecond: result.tokensPerSecond,
                stopReason: stopReason,
                wordsPerSecond: wps,
                decoderLoopPeriod: loopPeriod,
                decoderLoopRepeatCount: loopRepeatCount,
                promptEchoDetected: echoDetected
            )
        }
    }
    #else
    public func generateDetailed(
        prompt: String,
        maxTokens: Int,
        temperature: Double,
        cancellationID: UUID
    ) async throws -> GenerationMetrics {
        throw BCIError.predictorInferenceFailed(reason: "MLX modules not importable")
    }
    #endif

    #if canImport(MLX) && canImport(MLXLLM) && canImport(MLXLMCommon)
    /// Builds the token sequence to decode from: build prompt -> encode.
    /// Prefers the tokenizer's own chat template when it has one; falls
    /// back to a manual, model-specific framing otherwise. Kept separate
    /// from `generate` so prompt construction can be reasoned about (and
    /// eventually tested) independently of decoding.
    private static func tokenIDs(for text: String, tokenizer: any Tokenizer) throws -> [Int] {
        if tokenizer.hasChatTemplate {
            let messages: [Message] = [
                ["role": "system", "content": "You are a helpful assistant."],
                ["role": "user", "content": text],
            ]
            return try tokenizer.applyChatTemplate(messages: messages)
        }
        // No known message-template contract on this tokenizer — fall back
        // to a manual, model-specific framing. Qwen ChatML today; a model
        // family without a real `chat_template.json` would need its own
        // branch here until every backend we support ships one.
        return tokenizer.encode(text: chatMLPrompt(for: text))
    }

    private static func chatMLPrompt(for text: String) -> String {
        "<|im_start|>system\nYou are a helpful assistant.<|im_end|>\n"
            + "<|im_start|>user\n\(text)<|im_end|>\n<|im_start|>assistant\n"
    }

    /// Debug-only instrumentation for diagnosing decoder degeneration
    /// (repetitive loops that run to `maxTokens` instead of stopping
    /// cleanly). Logged at `.debug` level with generated text kept out of
    /// the message entirely — this is a local-only diagnostic aid, not a
    /// UI surface or telemetry, and deliberately doesn't persist the user's
    /// composed text even to the local unified log.
    private static func logGenerationDiagnostics(result: GenerateResult, maxTokens: Int) {
        let stoppedAtCap = result.tokens.count >= maxTokens
        let (period, repeatCount) = maxRepeatedNGram(in: result.output)
        BCILog.predictor.debug("""
            generation diagnostics: tokens=\(result.tokens.count, privacy: .public)\
            /\(maxTokens, privacy: .public) \
            stopReason=\(stoppedAtCap ? "maxTokens" : "eos", privacy: .public) \
            maxRepeatedNGram=period\(period, privacy: .public)x\(repeatCount, privacy: .public)
            """)
        // Not currently logged, and not trivial to add: per-step entropy /
        // top-1 probability, and the token index where a repetition run
        // first begins. Both would require bypassing the high-level
        // `MLXLMCommon.generate(...)` convenience wrapper for the
        // lower-level `TokenIterator` API and reimplementing the decode
        // loop this code otherwise gets for free — a real feature, not a
        // side effect of this bug fix. `cancelled` isn't a reachable stop
        // reason here either: cancellation throws out of `generate` (via
        // `Task.checkCancellation()`) before a `GenerateResult` exists.
    }

    /// Detects whether the model echoed the prompt back instead of producing
    /// a response. Checks if the trimmed output starts with a substantial
    /// prefix of the prompt text (≥ 50% of prompt words, minimum 3 words).
    /// A known failure mode for small models without proper chat framing.
    private static func detectPromptEcho(prompt: String, output: String) -> Bool {
        let promptWords = prompt.lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
        let outputWords = output.lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
        guard promptWords.count >= 3, outputWords.count >= 3 else { return false }

        // Check if output starts with ≥ 50% of prompt words in order
        let minMatch = max(3, promptWords.count / 2)
        var matchCount = 0
        for i in 0 ..< min(promptWords.count, outputWords.count) {
            if promptWords[i] == outputWords[i] {
                matchCount += 1
            } else {
                break
            }
        }
        return matchCount >= minMatch
    }

    /// Longest short-period decoding loop found in `text` — a short word
    /// n-gram (period 1-3) recurring immediately and mechanically, e.g.
    /// "and a and a and a" -> (period: 2, repeatCount: 3). This is a
    /// specific decoder pathology, not "repetition" in general: the same
    /// failure shape regardless of whether the surface content is "and a"
    /// or "one two three." Finds, for each candidate period and start
    /// position, how many consecutive times that exact slice repeats,
    /// rather than comparing single positions at a fixed lag (which
    /// doesn't actually verify the whole n-gram repeats, and can under- or
    /// over-count depending on period). Same detection idea as
    /// `MLXGenerationRegressionTests`'s loop check, deliberately duplicated
    /// rather than shared: one is a lightweight debug log, the other a
    /// hard test assertion.
    private static func maxRepeatedNGram(in text: String) -> (period: Int, repeatCount: Int) {
        let words = text.lowercased().split(separator: " ").map(String.init)
        var best = (period: 0, repeatCount: 1)
        for period in 1...3 {
            guard words.count >= period * 2 else { continue }
            var start = 0
            while start + period * 2 <= words.count {
                let candidate = Array(words[start..<(start + period)])
                var repeatCount = 1
                var next = start + period
                while next + period <= words.count,
                      Array(words[next..<(next + period)]) == candidate {
                    repeatCount += 1
                    next += period
                }
                if repeatCount > best.repeatCount { best = (period, repeatCount) }
                start += 1
            }
        }
        return best
    }
    #endif

    /// True when a decoded token represents the start of a real word: leading
    /// space, plus body composed of letters / digits / `'` / `-`. Rejects
    /// punctuation-only tokens, numeric-only tokens, and within-word fragments.
    private static func isWordStart(_ decoded: String) -> Bool {
        guard decoded.first == " " else { return false }
        let body = decoded.dropFirst()
        guard let first = body.first, first.isLetter else { return false }
        return body.allSatisfy { $0.isLetter || $0.isNumber || $0 == "'" || $0 == "-" }
    }
}
