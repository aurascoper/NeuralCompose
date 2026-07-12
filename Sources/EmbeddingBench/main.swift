import BCIClassifier
import BCICore
import Foundation

// Stage 3.2: try the real BGE-small-en-v1.5 Core ML backend first; fall back
// to the deterministic stub if `Scripts/convert-sentence-embedder.py` hasn't
// been run yet — same "stub-by-default" convention as the rest of the app
// (CLAUDE.md), not a runtime-selection registry. `BenchmarkRunner` itself is
// unchanged either way.
let modelDirectory = URL(fileURLWithPath: "Models/BGE-small-en-v1.5")

let embedder: any SentenceEmbedder
let runtime: String
let pooling: String
let coremlSHA256: String
let tokenizerSHA256: String

if let coreML = try? CoreMLSentenceEmbedder(modelDirectory: modelDirectory) {
    embedder = coreML
    runtime = "coreml"
    pooling = coreML.poolingDescription
    // Hash whichever artifact is actually on disk — CoreMLSentenceEmbedder
    // itself prefers a precompiled model.mlmodelc but falls back to
    // model.mlpackage (JIT-compiled at load time), and convert-sentence-
    // embedder.py only ever produces the latter.
    let mlmodelcURL = modelDirectory.appendingPathComponent("model.mlmodelc")
    let mlpackageURL = modelDirectory.appendingPathComponent("model.mlpackage")
    let modelArtifactURL = FileManager.default.fileExists(atPath: mlmodelcURL.path) ? mlmodelcURL : mlpackageURL
    coremlSHA256 = SystemInfo.sha256(ofDirectoryAt: modelArtifactURL)
    tokenizerSHA256 = SystemInfo.sha256(ofFileAt: modelDirectory.appendingPathComponent("tokenizer.json"))
    print("Benchmarking CoreMLSentenceEmbedder at \(modelDirectory.path)")
} else {
    embedder = DeterministicSentenceEmbedder(dimension: 384, seed: 0)
    runtime = "stub"
    pooling = "n/a"
    coremlSHA256 = ""
    tokenizerSHA256 = ""
    print("No model at \(modelDirectory.path) — benchmarking DeterministicSentenceEmbedder instead")
}

let result = try await BenchmarkRunner.run(
    embedder: embedder,
    runtime: runtime,
    pooling: pooling,
    coremlSHA256: coremlSHA256,
    tokenizerSHA256: tokenizerSHA256
)

let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
let data = try encoder.encode(result)

let dateFormatter = DateFormatter()
dateFormatter.dateFormat = "yyyy-MM-dd"
dateFormatter.timeZone = TimeZone(identifier: "UTC")
let dateStamp = dateFormatter.string(from: Date())

let outputDirectory = URL(fileURLWithPath: "Benchmarks")
try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
let outputURL = outputDirectory.appendingPathComponent("\(dateStamp)-\(result.modelID).json")
try data.write(to: outputURL)

print("Wrote \(outputURL.path)")
