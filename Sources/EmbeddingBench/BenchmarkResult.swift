import Foundation

/// Frozen benchmark schema — `docs/architecture/embedding_contract.md` §6.
///
/// Adding a field is additive. Changing the meaning of an existing field
/// requires bumping `schemaVersion` and updating the contract doc (§6.5).
struct BenchmarkResult: Codable {
    let schemaVersion: Int
    let modelID: String
    let runtime: String
    let device: String
    let macos: String
    let buildSHA: String
    let coremlSHA256: String
    let tokenizerSHA256: String
    let dimension: Int
    let coldLoadMs: Double
    let warmEncodeMs: Double
    let batchSizes: [String: Double]
    let rssMB: Double
    let embeddingsPerSecond: Double

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case modelID = "model_id"
        case runtime
        case device
        case macos
        case buildSHA = "build_sha"
        case coremlSHA256 = "coreml_sha256"
        case tokenizerSHA256 = "tokenizer_sha256"
        case dimension
        case coldLoadMs = "cold_load_ms"
        case warmEncodeMs = "warm_encode_ms"
        case batchSizes = "batch_sizes"
        case rssMB = "rss_mb"
        case embeddingsPerSecond = "embeddings_per_second"
    }

    init(
        modelID: String,
        runtime: String,
        device: String,
        macos: String,
        buildSHA: String,
        coremlSHA256: String,
        tokenizerSHA256: String,
        dimension: Int,
        coldLoadMs: Double,
        warmEncodeMs: Double,
        batchSizes: [String: Double],
        rssMB: Double,
        embeddingsPerSecond: Double
    ) {
        self.schemaVersion = 1
        self.modelID = modelID
        self.runtime = runtime
        self.device = device
        self.macos = macos
        self.buildSHA = buildSHA
        self.coremlSHA256 = coremlSHA256
        self.tokenizerSHA256 = tokenizerSHA256
        self.dimension = dimension
        self.coldLoadMs = coldLoadMs
        self.warmEncodeMs = warmEncodeMs
        self.batchSizes = batchSizes
        self.rssMB = rssMB
        self.embeddingsPerSecond = embeddingsPerSecond
    }
}
