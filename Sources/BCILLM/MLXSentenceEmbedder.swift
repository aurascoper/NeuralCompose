import BCICore
import Foundation
import MLX
import MLXEmbedders
import Tokenizers

/// MLX-backed `SentenceEmbedder` for sentence-transformers-format models
/// (BERT/RoBERTa/XLM-R/NomicBERT families via `MLXEmbedders`).
///
/// Stage 3.4 RQ1 instrumentation: exists so the same model can be measured
/// through `BenchmarkRunner` on the MLX runtime and compared against the
/// Python (fp32 torch) and Core ML paths by
/// `Evaluation/scripts/cross_runtime_consistency.py`. Whether this becomes a
/// production backend is a separate engineering decision deferred until after
/// Stage 3.5 — nothing in `AppContainer` constructs it.
///
/// `modelDirectory` is a HuggingFace snapshot of a sentence-transformers
/// model: `config.json` + `*.safetensors` + tokenizer files + the
/// `1_Pooling/config.json` that records the model's pooling strategy.
/// Pooling is metadata, never hardcoded — same convention as
/// `CoreMLSentenceEmbedder`'s `metadata.json` (and the conversion script's
/// self-verification that wrote it). A directory without a pooling config is
/// rejected rather than guessed at.
///
/// Same isolation discipline as everything in BCILLM: only plain-Swift
/// `Embedding` values cross the boundary — no `MLXArray` in any signature
/// (`SentenceEmbedder` doc, Package.swift MLX note). Inference is serial
/// per text inside the batch call, mirroring `CoreMLSentenceEmbedder` —
/// batch-shape parity between the two backends keeps RQ1 latency
/// comparisons about the runtime, not the batching strategy.
public final class MLXSentenceEmbedder: SentenceEmbedder, Sendable {
    public let modelID: String
    public let version = "1"
    public let dimension: Int

    /// `"cls"`, `"mean"`, `"max"`, `"last"`, or `"first"` as recorded in
    /// `1_Pooling/config.json`. Not part of the protocol — exposed on the
    /// concrete type so `EmbeddingBench` can record it, same as the CoreML
    /// conformer.
    public let poolingDescription: String

    private let container: MLXEmbedders.ModelContainer

    public init(modelDirectory: URL, modelID: String? = nil) async throws {
        let poolingURL = modelDirectory
            .appendingPathComponent("1_Pooling")
            .appendingPathComponent("config.json")
        guard FileManager.default.fileExists(atPath: poolingURL.path) else {
            throw BCIError.embedderMetadataInvalid(
                path: poolingURL.path,
                reason: "missing 1_Pooling/config.json — pooling is metadata, never guessed"
            )
        }
        let poolingConfig: PoolingConfiguration
        do {
            let data = try Data(contentsOf: poolingURL)
            poolingConfig = try Self.decodePoolingConfiguration(from: data)
        } catch {
            throw BCIError.embedderMetadataInvalid(
                path: poolingURL.path,
                reason: error.localizedDescription
            )
        }

        self.poolingDescription = Self.poolingLabel(for: poolingConfig)
        self.dimension = poolingConfig.dimension
        self.modelID = modelID ?? modelDirectory.lastPathComponent

        // `.directory` configurations never touch the network: weights,
        // config, tokenizer, and pooling all come from the local snapshot
        // (offline-first, like every model load in this app).
        let configuration = ModelConfiguration(directory: modelDirectory)
        do {
            self.container = try await MLXEmbedders.loadModelContainer(
                configuration: configuration)
        } catch {
            throw BCIError.embedderLoadFailed(
                path: modelDirectory.path,
                underlying: error.localizedDescription
            )
        }
    }

    public func encode(_ texts: [String]) async throws -> [Embedding] {
        var results: [Embedding] = []
        results.reserveCapacity(texts.count)
        for text in texts {
            results.append(try await embed(text))
        }
        return results
    }

    // MARK: - Per-text inference

    private func embed(_ text: String) async throws -> Embedding {
        let expectedDimension = dimension
        let poolingLabel = poolingDescription
        let values: [Float] = await container.perform { model, tokenizer, _ in
            let tokens = tokenizer.encode(text: text)
            guard !tokens.isEmpty else {
                // Deterministic finite fallback for input the tokenizer
                // reduces to nothing (ADR-004 §3.1) — same shape of answer
                // as CoreMLSentenceEmbedder's degenerate-norm path.
                return Self.axisUnitVector(dimension: expectedDimension)
            }
            let inputs = MLXArray(tokens.map(Int32.init)).expandedDimensions(axis: 0)
            // Single unpadded sequence: every position is real, so the
            // model's default (nil) attention mask is correct and the
            // pooler's implicit all-ones mask matches. Token types must be
            // explicit zeros, NOT nil: MLXEmbedders' BertEmbedding skips the
            // segment embedding entirely when the ids are nil, while HF BERT
            // adds segment-0 unconditionally — the omission shifts every
            // position by a learned constant (caught by RQ1 cross-runtime
            // consistency: MiniLM python↔mlx cosine 0.756 before, ~1 after).
            let output = model(
                inputs, positionIds: nil,
                tokenTypeIds: MLXArray.zeros(inputs.shape, type: Int32.self),
                attentionMask: nil)
            // The container's own pooler is ignored: MLXEmbedders'
            // loadPooling silently degrades to Strategy.none when the
            // pooling config fails its strict decode (every pre-lasttoken
            // sentence-transformers file does), which would emit unpooled
            // hidden states. Rebuild the pooler from the tolerantly-decoded
            // strategy instead — same Pooling type, no silent fallback.
            let pooler = Pooling(
                strategy: Self.poolingStrategy(for: poolingLabel),
                dimension: expectedDimension)
            let pooled = pooler(output, normalize: true)
            eval(pooled)
            return pooled.asArray(Float.self)
        }

        guard values.count == expectedDimension else {
            throw BCIError.embedderOutputShapeUnexpected(
                expected: "[\(expectedDimension)]",
                actual: "[\(values.count)]"
            )
        }
        guard values.allSatisfy(\.isFinite) else {
            throw BCIError.embedderInferenceFailed(
                reason: "non-finite value in pooled embedding")
        }

        // The pooler already normalized; re-normalize on the Swift side so
        // the ADR-004 §3.1 unit-norm invariant never depends on upstream
        // library behavior, with the axis fallback for degenerate vectors.
        let normalized = Self.l2Normalized(values) ?? Self.axisUnitVector(dimension: expectedDimension)

        return Embedding(
            values: normalized, modelID: modelID, dimension: expectedDimension,
            version: version, seed: 0)
    }

    // MARK: - Pure helpers (seam-tested in MLXSentenceEmbedderTests)

    /// Decodes a sentence-transformers `1_Pooling/config.json`, tolerating
    /// the older file format that omits keys for pooling modes introduced
    /// later (e.g. bge-small's file predates `pooling_mode_lasttoken`).
    /// An absent mode key means `false` — sentence-transformers' own
    /// semantics — so normalize before handing the JSON to MLXEmbedders'
    /// strict `Codable`. `word_embedding_dimension` has no safe default
    /// and still must be present.
    static func decodePoolingConfiguration(from data: Data) throws -> PoolingConfiguration {
        guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw DecodingError.dataCorrupted(DecodingError.Context(
                codingPath: [], debugDescription: "pooling config is not a JSON object"))
        }
        for key in [
            "pooling_mode_cls_token", "pooling_mode_mean_tokens",
            "pooling_mode_max_tokens", "pooling_mode_lasttoken",
        ] where object[key] == nil {
            object[key] = false
        }
        let normalized = try JSONSerialization.data(withJSONObject: object)
        return try JSONDecoder().decode(PoolingConfiguration.self, from: normalized)
    }

    /// Rebuilds the `Pooling` strategy from the stored label inside the
    /// inference closure (a `String` crosses the `@Sendable` boundary; the
    /// module type need not).
    ///
    /// "cls" deliberately maps to `.first`, not `.cls`:
    /// sentence-transformers' `pooling_mode_cls_token` is the RAW hidden
    /// state at position 0, but `Pooling`'s `.cls` prefers the BertModel
    /// pooler head — `tanh(dense(cls))` — when present, a different vector
    /// entirely (caught by RQ1 cross-runtime consistency: bge-small
    /// python↔mlx cosine -0.05 through the pooler head). `.first` is
    /// exactly the raw position-0 vector.
    static func poolingStrategy(for label: String) -> Pooling.Strategy {
        switch label {
        case "cls": return .first
        case "mean": return .mean
        case "max": return .max
        case "last": return .last
        default: return .first
        }
    }

    /// Maps a sentence-transformers pooling config to its label, with the
    /// same precedence `MLXEmbedders.Pooling` applies: cls > mean > max >
    /// last > first.
    static func poolingLabel(for config: PoolingConfiguration) -> String {
        if config.poolingModeClsToken { return "cls" }
        if config.poolingModeMeanTokens { return "mean" }
        if config.poolingModeMaxTokens { return "max" }
        if config.poolingModeLastToken { return "last" }
        return "first"
    }

    static func l2Normalized(_ v: [Float]) -> [Float]? {
        var sumSq: Float = 0
        for x in v { sumSq += x * x }
        let norm = sumSq.squareRoot()
        guard norm > 1e-6 else { return nil }
        return v.map { $0 / norm }
    }

    static func axisUnitVector(dimension: Int) -> [Float] {
        var v = [Float](repeating: 0, count: dimension)
        v[0] = 1
        return v
    }
}
