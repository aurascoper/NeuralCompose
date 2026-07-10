import Foundation
import BCICore

#if canImport(MLX) && canImport(MLXLLM) && canImport(MLXLMCommon)
import MLX
import MLXLLM
import MLXLMCommon
import Tokenizers
#endif

/// MLX-Swift-backed next-word predictor.
///
/// Loads an MLX-converted causal LM from a local directory and serves
/// top-K next-word candidates via a single forward pass per call. Word
/// boundaries are detected by the BPE convention: a token whose decoded
/// text starts with a space is a complete word start.
///
/// Threading: actor. Forward passes are serialized by the underlying
/// `ModelContainer` — running two on the Apple GPU at once just thrashes.
public actor MLXNextWordPredictor: NextWordPredicting, TokenEmbeddingProviding {

    public nonisolated let isLive: Bool = true
    public nonisolated let modelIdentifier: String

    #if canImport(MLX) && canImport(MLXLLM) && canImport(MLXLMCommon)
    private let container: ModelContainer
    #endif

    public init(modelDirectory: URL) async throws {
        guard FileManager.default.fileExists(atPath: modelDirectory.path) else {
            throw BCIError.predictorWeightsMissing(path: modelDirectory.path)
        }
        self.modelIdentifier = modelDirectory.lastPathComponent

        #if canImport(MLX) && canImport(MLXLLM) && canImport(MLXLMCommon)
        let configuration = ModelConfiguration(directory: modelDirectory)
        do {
            self.container = try await LLMModelFactory.shared.loadContainer(
                configuration: configuration
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
