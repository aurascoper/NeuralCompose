import BCIClassifier
import BCICore
import BCILLM
import Foundation

// Stage 3.2 measured the Core ML BGE-small backend; Stage 3.4 RQ1 adds
// `--backend mlx` so the same `BenchmarkRunner` code path measures an
// `MLXSentenceEmbedder`. Backend selection is argument parsing over concrete
// conformers — the same "not a runtime-selection registry" convention as
// SemanticEval (CLAUDE.md). `BenchmarkRunner` is unchanged either way
// (ADR-010 §3.5 Gate 1: it never sees a backend-specific type).
//
// Flags (all optional — bare invocation behaves exactly as it did in
// Stage 3.2: try Core ML at Models/BGE-small-en-v1.5, else stub):
//   --backend coreml|mlx|stub   force a backend instead of auto-detect
//   --model-dir PATH            model directory for coreml/mlx backends
//   --model-name NAME           label used in the eval-layout checkpoint
//   --repo-id ID                HF repo recorded in the eval-layout checkpoint
//   --corpus PATH               corpus JSON for the embedding sample
//                               (default Evaluation/corpora/embedding_bench_corpus_v1.json)
//   --output-dir PATH           ALSO emit an eval-layout checkpoint
//                               (<output-dir>/<model-name>/<runtime>/benchmark.json)
//                               for cross_runtime_consistency.py; the dated
//                               Benchmarks/ record is written regardless.

struct CLIArguments {
    var backend: String?
    var modelDir: String?
    var modelName: String?
    var repoID: String?
    var corpus = "Evaluation/corpora/embedding_bench_corpus_v1.json"
    var outputDir: String?

    init(_ arguments: [String]) {
        var i = 1
        while i < arguments.count {
            let flag = arguments[i]
            let value = i + 1 < arguments.count ? arguments[i + 1] : nil
            switch flag {
            case "--backend": backend = value; i += 2
            case "--model-dir": modelDir = value; i += 2
            case "--model-name": modelName = value; i += 2
            case "--repo-id": repoID = value; i += 2
            case "--corpus": corpus = value ?? corpus; i += 2
            case "--output-dir": outputDir = value; i += 2
            default:
                FileHandle.standardError.write(Data("Unknown flag: \(flag)\n".utf8))
                exit(2)
            }
        }
    }
}

/// Only the corpus text list is needed here; the Python pipeline owns the
/// rest of the fixture (queries, pairs, trajectories).
struct BenchCorpus: Decodable {
    let corpus: [String]
}

let args = CLIArguments(CommandLine.arguments)

let defaultCoreMLDirectory = "Models/BGE-small-en-v1.5"
let embedder: any SentenceEmbedder
let runtime: String
let pooling: String
let coremlSHA256: String
let tokenizerSHA256: String
var weightsSHA256 = ""

switch args.backend {
case "mlx":
    guard let modelDir = args.modelDir else {
        FileHandle.standardError.write(Data("--backend mlx requires --model-dir\n".utf8))
        exit(2)
    }
    let modelDirectory = URL(fileURLWithPath: modelDir)
    let mlx = try await MLXSentenceEmbedder(
        modelDirectory: modelDirectory, modelID: args.modelName)
    embedder = mlx
    // "mlx-swift" (not "mlx"): the Python pipeline already uses "mlx" for its
    // mlx_lm runtime — distinct labels keep the two separable in
    // cross_runtime_consistency.py's pairwise comparisons.
    runtime = "mlx-swift"
    pooling = mlx.poolingDescription
    coremlSHA256 = ""
    weightsSHA256 = SystemInfo.sha256(ofDirectoryAt: modelDirectory)
    let tokenizerURL = modelDirectory.appendingPathComponent("tokenizer.json")
    tokenizerSHA256 = FileManager.default.fileExists(atPath: tokenizerURL.path)
        ? SystemInfo.sha256(ofFileAt: tokenizerURL) : ""
    print("Benchmarking MLXSentenceEmbedder at \(modelDirectory.path) (pooling: \(pooling))")

case "stub":
    embedder = DeterministicSentenceEmbedder(dimension: 384, seed: 0)
    runtime = "stub"
    pooling = "n/a"
    coremlSHA256 = ""
    tokenizerSHA256 = ""
    print("Benchmarking DeterministicSentenceEmbedder (forced stub)")

case "coreml", nil:
    let modelDirectory = URL(fileURLWithPath: args.modelDir ?? defaultCoreMLDirectory)
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
        weightsSHA256 = coremlSHA256
        tokenizerSHA256 = SystemInfo.sha256(ofFileAt: modelDirectory.appendingPathComponent("tokenizer.json"))
        print("Benchmarking CoreMLSentenceEmbedder at \(modelDirectory.path)")
    } else if args.backend == "coreml" {
        FileHandle.standardError.write(
            Data("No loadable Core ML model at \(modelDirectory.path)\n".utf8))
        exit(1)
    } else {
        embedder = DeterministicSentenceEmbedder(dimension: 384, seed: 0)
        runtime = "stub"
        pooling = "n/a"
        coremlSHA256 = ""
        tokenizerSHA256 = ""
        print("No model at \(modelDirectory.path) — benchmarking DeterministicSentenceEmbedder instead")
    }

default:
    FileHandle.standardError.write(
        Data("Unknown --backend '\(args.backend ?? "")' (coreml|mlx|stub)\n".utf8))
    exit(2)
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

// Eval-layout checkpoint for RQ1 cross-runtime consistency (opt-in).
if let outputDir = args.outputDir {
    let corpusURL = URL(fileURLWithPath: args.corpus)
    let corpus = try JSONDecoder().decode(BenchCorpus.self, from: Data(contentsOf: corpusURL))
    let sampleTexts = Array(corpus.corpus.prefix(10))
    let sampleEmbeddings = try await embedder.encode(sampleTexts).map(\.values)

    let checkpointURL = try EvalCheckpointWriter.write(
        outputRoot: URL(fileURLWithPath: outputDir),
        modelName: args.modelName ?? result.modelID,
        repoID: args.repoID ?? "local-directory",
        runtime: runtime,
        result: result,
        sampleTexts: sampleTexts,
        sampleEmbeddings: sampleEmbeddings,
        weightsSHA256: weightsSHA256,
        tokenizerSHA256: tokenizerSHA256
    )
    print("Wrote \(checkpointURL.path)")
}
