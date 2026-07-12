import BCICore
import Foundation

/// Measures any `SentenceEmbedder` conformer. Deliberately generic — this
/// file must never import CoreML, MLX, or any backend-specific type
/// (ADR-004 §3.5 Gate 1). A future `CoreMLSentenceEmbedder` or
/// `MLXSentenceEmbedder` is measured through this exact same code path.
enum BenchmarkRunner {
    static let batchSizes = [1, 8, 32, 128]

    static func run(
        embedder: any SentenceEmbedder,
        runtime: String,
        pooling: String = "n/a",
        coremlSHA256: String = "",
        tokenizerSHA256: String = ""
    ) async throws -> BenchmarkResult {
        let sentences = sampleSentences

        // The protocol has no separate `load()` step, so the first `encode`
        // call is the proxy for "cold" cost — for a real backend this is
        // where lazy weight loading / ANE compilation would show up.
        let coldStart = DispatchTime.now()
        _ = try await embedder.encode([sentences[0]])
        let coldLoadMs = milliseconds(since: coldStart)

        // Warm: repeat the same single-item call now that any lazy init
        // has already paid its one-time cost.
        let warmStart = DispatchTime.now()
        _ = try await embedder.encode([sentences[0]])
        let warmEncodeMs = milliseconds(since: warmStart)

        var batchMs: [String: Double] = [:]
        var lastBatchCount = 0
        var lastBatchSeconds: Double = 0
        for size in batchSizes {
            let batch = (0..<size).map { sentences[$0 % sentences.count] }
            let start = DispatchTime.now()
            let results = try await embedder.encode(batch)
            let ms = milliseconds(since: start)
            batchMs["\(size)"] = ms
            lastBatchCount = results.count
            lastBatchSeconds = ms / 1000
        }

        let embeddingsPerSecond = lastBatchSeconds > 0
            ? Double(lastBatchCount) / lastBatchSeconds
            : 0

        return BenchmarkResult(
            modelID: embedder.modelID,
            runtime: runtime,
            device: SystemInfo.device(),
            macos: SystemInfo.macOSVersion(),
            buildSHA: SystemInfo.buildSHA(),
            // Empty for a backend with no model/tokenizer file on disk (the
            // stub); the caller (main.swift) supplies real hashes for a
            // CoreMLSentenceEmbedder.
            coremlSHA256: coremlSHA256,
            tokenizerSHA256: tokenizerSHA256,
            dimension: embedder.dimension,
            coldLoadMs: coldLoadMs,
            warmEncodeMs: warmEncodeMs,
            batchSizes: batchMs,
            rssMB: SystemInfo.residentSetSizeMB(),
            embeddingsPerSecond: embeddingsPerSecond,
            pooling: pooling
        )
    }

    private static func milliseconds(since start: DispatchTime) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
    }

    private static let sampleSentences = [
        "The quick brown fox jumps over the lazy dog.",
        "I would like a glass of water, please.",
        "Turn the lights off before you leave the room.",
        "The intent classifier fires on jaw-clench events.",
        "Deep sleep restores the body and mind.",
    ]
}
