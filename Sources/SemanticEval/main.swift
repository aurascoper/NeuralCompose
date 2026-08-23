import BCIClassifier
import BCICore
import Foundation

// Stage 3.3: emits raw semantic evidence (embeddings, cosine relationships)
// for whichever `SentenceEmbedder` conformer `--model` names — no
// projection, no clustering metrics here. Those are derived, display/
// analysis choices that belong downstream in
// Scripts/generate-semantic-eval-artifacts.py, regenerable without
// rerunning the model.

func parseModelFlag() -> String {
    let args = CommandLine.arguments
    if let idx = args.firstIndex(of: "--model"), idx + 1 < args.count {
        return args[idx + 1]
    }
    for arg in args where arg.hasPrefix("--model=") {
        return String(arg.dropFirst("--model=".count))
    }
    return "bge"
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(1)
}

/// Pure — takes `embeddingByText` as a parameter rather than capturing a
/// global, so it stays outside the top-level script's actor isolation.
func pairScores(_ pairs: [[String]], embeddingByText: [String: Embedding]) -> [SemanticEvalResult.PairScore] {
    pairs.map { pair in
        let a = pair[0], b = pair[1]
        let score = embeddingByText[a]!.cosineSimilarity(to: embeddingByText[b]!)!
        return .init(a: a, b: b, score: score)
    }
}

/// Pure, same reasoning as `pairScores`.
func meanPairwiseSimilarity(_ texts: [String], embeddingByText: [String: Embedding]) -> Float {
    guard texts.count > 1 else { return 1 }
    var total: Float = 0
    var count = 0
    for i in 0..<texts.count {
        for j in (i + 1)..<texts.count {
            total += embeddingByText[texts[i]]!.cosineSimilarity(to: embeddingByText[texts[j]]!)!
            count += 1
        }
    }
    return count > 0 ? total / Float(count) : 1
}

let modelName = parseModelFlag()

// Adding a second conformer means adding one case here, not restructuring
// the tool — everything below touches only `any SentenceEmbedder`. This is
// argument parsing, not a backend registry: no runtime discovery, no
// plugin surface.
let embedder: any SentenceEmbedder
switch modelName {
case "bge":
    do {
        embedder = try CoreMLSentenceEmbedder(
            modelDirectory: URL(fileURLWithPath: "Models/BGE-small-en-v1.5")
        )
    } catch {
        fail("No BGE model at Models/BGE-small-en-v1.5 (\(error)). Run "
            + "Scripts/convert-sentence-embedder.py --model BAAI/bge-small-en-v1.5 first. "
            + "(SemanticEval never falls back to the deterministic stub — "
            + "evaluating its decorative space would produce meaningless evidence.)")
    }
default:
    fail("Unknown --model '\(modelName)' — no conformer registered for it yet.")
}

// MARK: - Load corpus config

let configURL = URL(fileURLWithPath: "Evaluation/corpora/semantic_eval_v1.json")
let configData = try Data(contentsOf: configURL)
let config = try JSONDecoder().decode(SemanticEvalConfig.self, from: configData)

// MARK: - Embed every phrase referenced anywhere in the config, once

var allPhrases: [String] = []
var seenPhrases = Set<String>()
for text in config.corpus where seenPhrases.insert(text).inserted { allPhrases.append(text) }
for text in config.queries where seenPhrases.insert(text).inserted { allPhrases.append(text) }
for phrases in config.commandGroups.values {
    for text in phrases where seenPhrases.insert(text).inserted { allPhrases.append(text) }
}
for pair in config.paraphrasePairs {
    for text in pair where seenPhrases.insert(text).inserted { allPhrases.append(text) }
}
for pair in config.antonymPairs {
    for text in pair where seenPhrases.insert(text).inserted { allPhrases.append(text) }
}
for trajectory in config.trajectories {
    for text in trajectory.phrases where seenPhrases.insert(text).inserted { allPhrases.append(text) }
}

let embeddings = try await embedder.encode(allPhrases)
var embeddingByText: [String: Embedding] = [:]
for (text, embedding) in zip(allPhrases, embeddings) {
    embeddingByText[text] = embedding
}

// MARK: - All-pairs cosine matrix over the corpus

let corpusEmbeddings = config.corpus.map { embeddingByText[$0]! }
var cosineMatrixValues = Array(
    repeating: [Float](repeating: 0, count: config.corpus.count),
    count: config.corpus.count
)
for i in 0..<config.corpus.count {
    for j in 0..<config.corpus.count {
        cosineMatrixValues[i][j] = corpusEmbeddings[i].cosineSimilarity(to: corpusEmbeddings[j])!
    }
}

// MARK: - Top-k neighbors per query

var neighborsResult: [String: [SemanticEvalResult.NeighborScore]] = [:]
for query in config.queries {
    let queryEmbedding = embeddingByText[query]!
    let neighbors = NearestNeighbors.topK(
        query: queryEmbedding,
        corpusTexts: config.corpus,
        corpusEmbeddings: corpusEmbeddings,
        k: config.topK
    )
    neighborsResult[query] = neighbors.map { .init(text: $0.text, score: $0.score) }
}

// MARK: - Paraphrase / antonym pair scores

let paraphraseScores = pairScores(config.paraphrasePairs, embeddingByText: embeddingByText)
let antonymScores = pairScores(config.antonymPairs, embeddingByText: embeddingByText)

// MARK: - Command-group cohesion (intra-group mean, cross-group mean)

var commandGroupResults: [String: SemanticEvalResult.CommandGroupResult] = [:]
for (name, phrases) in config.commandGroups {
    commandGroupResults[name] = .init(
        phrases: phrases,
        intraMeanSimilarity: meanPairwiseSimilarity(phrases, embeddingByText: embeddingByText)
    )
}

var crossTotal: Float = 0
var crossCount = 0
let groupNames = Array(config.commandGroups.keys)
for gi in 0..<groupNames.count {
    for gj in (gi + 1)..<groupNames.count {
        let phrasesA = config.commandGroups[groupNames[gi]]!
        let phrasesB = config.commandGroups[groupNames[gj]]!
        for a in phrasesA {
            for b in phrasesB {
                crossTotal += embeddingByText[a]!.cosineSimilarity(to: embeddingByText[b]!)!
                crossCount += 1
            }
        }
    }
}
let crossCommandMeanSimilarity: Float = crossCount > 0 ? crossTotal / Float(crossCount) : 0

// MARK: - Trajectory embeddings + step-to-step cosine similarity

var trajectoryResults: [String: SemanticEvalResult.TrajectoryResult] = [:]
for trajectory in config.trajectories {
    let phraseEmbeddings = trajectory.phrases.map { embeddingByText[$0]! }
    var stepSimilarities: [Float] = []
    for i in 0..<(phraseEmbeddings.count - 1) {
        stepSimilarities.append(phraseEmbeddings[i].cosineSimilarity(to: phraseEmbeddings[i + 1])!)
    }
    trajectoryResults[trajectory.name] = .init(
        phrases: trajectory.phrases,
        embeddings: phraseEmbeddings.map { $0.values },
        stepCosineSimilarities: stepSimilarities
    )
}

// MARK: - Assemble + write

let poolingDescription = (embedder as? CoreMLSentenceEmbedder)?.poolingDescription ?? "n/a"

let result = SemanticEvalResult(
    schemaVersion: 1,
    provenance: .init(
        modelID: embedder.modelID,
        version: embedder.version,
        pooling: poolingDescription,
        dimension: embedder.dimension,
        gitCommit: GitInfo.commitSHA(),
        evaluationCorpus: "semantic_eval_v1",
        evaluationCorpusVersion: config.version,
        projectionSeed: 0x5EED_C0DE
    ),
    phrases: allPhrases.map { .init(text: $0, embedding: embeddingByText[$0]!.values) },
    cosineMatrix: .init(texts: config.corpus, matrix: cosineMatrixValues),
    neighbors: neighborsResult,
    paraphrasePairs: paraphraseScores,
    antonymPairs: antonymScores,
    commandGroups: commandGroupResults,
    crossCommandMeanSimilarity: crossCommandMeanSimilarity,
    trajectories: trajectoryResults
)

let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
let data = try encoder.encode(result)

let dateFormatter = DateFormatter()
dateFormatter.dateFormat = "yyyy-MM-dd"
dateFormatter.timeZone = TimeZone(identifier: "UTC")
let dateStamp = dateFormatter.string(from: Date())

let outputDir = URL(fileURLWithPath: "Evaluation")
    .appendingPathComponent("\(dateStamp)-\(result.provenance.modelID)")
try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
let outputURL = outputDir.appendingPathComponent("data.json")
try data.write(to: outputURL)

print("Wrote \(outputURL.path)")
