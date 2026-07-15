import Foundation

/// Emits a benchmark checkpoint in the Python evaluation pipeline's layout:
/// `Evaluation/results/embeddings/<model>/<runtime>/benchmark.json`.
///
/// These checkpoints exist for Stage 3.4 RQ1 (cross-runtime consistency):
/// `cross_runtime_consistency.py` compares the stored `embedding_sample`
/// (first 10 corpus texts, embedded at run time) across runtimes. They are
/// deliberately NOT leaderboard entries — they carry no quality/stability
/// metric blocks, so `regenerate_leaderboard.py`'s `extract_metrics()`
/// skips them. `validate_checkpoints.py` validates them against the reduced
/// RQ1 schema keyed on runtime ∈ {coreml, mlx-swift, stub}.
///
/// Direct emission (rather than converting `Benchmarks/*.json` post hoc)
/// because the embedding sample only exists while the model is loaded.
/// The dated `Benchmarks/` record remains the frozen historical schema;
/// this is an additional output, not a replacement.
struct EvalCheckpointWriter {
    struct EmbeddingSample: Codable {
        let texts: [String]
        let embeddings: [[Float]]
        let dimension: Int
    }

    struct Provenance: Codable {
        let git_commit: String
        let device: String
        let macos_version: String
        let harness: String
        let pooling: String
        let weights_sha256: String
        let tokenizer_sha256: String
    }

    struct Checkpoint: Codable {
        let model_name: String
        let repo_id: String
        let runtime: String
        let timestamp: String
        let status: String
        let schema_version: Int
        /// Seconds — the Python pipeline stores seconds; BenchmarkRunner
        /// measures milliseconds. Divergent units here would silently corrupt
        /// every cross-runtime latency comparison.
        let cold_load_time: Double
        let warm_encode_time_ms: Double
        let embeddings_per_second: Double
        let dimension: Int
        let peak_rss_mb: Double
        let embedding_sample: EmbeddingSample
        let provenance: Provenance
    }

    static func write(
        outputRoot: URL,
        modelName: String,
        repoID: String,
        runtime: String,
        result: BenchmarkResult,
        sampleTexts: [String],
        sampleEmbeddings: [[Float]],
        weightsSHA256: String,
        tokenizerSHA256: String
    ) throws -> URL {
        let checkpoint = Checkpoint(
            model_name: modelName,
            repo_id: repoID,
            runtime: runtime,
            timestamp: ISO8601DateFormatter().string(from: Date()),
            status: "evaluated",
            schema_version: 1,
            cold_load_time: result.coldLoadMs / 1000.0,
            warm_encode_time_ms: result.warmEncodeMs,
            embeddings_per_second: result.embeddingsPerSecond,
            dimension: result.dimension,
            peak_rss_mb: result.rssMB,
            embedding_sample: EmbeddingSample(
                texts: sampleTexts,
                embeddings: sampleEmbeddings,
                dimension: result.dimension
            ),
            provenance: Provenance(
                git_commit: result.buildSHA,
                device: result.device,
                macos_version: result.macos,
                harness: "EmbeddingBench",
                pooling: result.pooling,
                weights_sha256: weightsSHA256,
                tokenizer_sha256: tokenizerSHA256
            )
        )

        let dir = outputRoot
            .appendingPathComponent(modelName)
            .appendingPathComponent(runtime)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let url = dir.appendingPathComponent("benchmark.json")
        try encoder.encode(checkpoint).write(to: url)
        return url
    }
}
