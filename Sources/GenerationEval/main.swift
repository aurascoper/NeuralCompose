import BCICore
import BCIClassifier
import BCILLM
import Foundation

// Runs every candidate in Evaluation/corpora/generation_eval_candidates_v1.json
// against every prompt in Evaluation/corpora/generation_eval_prompts_v1.json,
// emitting raw evidence (Evaluation/<date>-generation-eval/data.json) plus a
// scoring-template.csv for the dimensions that don't have a reliable
// automatic score (meaning preserved, grammar, no hallucination, no added
// commentary, conciseness, instruction followed — all left blank, 1-5, for
// manual review).
//
// Needs the Xcode-built binary to reach the real MLX path — same
// missing-metallib limitation as MLXProbe. Build via
// `xcodebuild -scheme GenerationEval -destination 'platform=macOS'
// -derivedDataPath .build/xcode build`, then run the product it produces
// directly (not `swift run`).
//
// Flags:
//   --candidates <path>   Override candidates fixture (default: .../generation_eval_candidates_v1.json)
//   --output-dir <path>   Override output directory (default: Evaluation/<date>-generation-eval)

func fail(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(1)
}

func wordCount(_ text: String) -> Int {
    text.split(whereSeparator: { $0.isWhitespace }).count
}

// MARK: - Parse arguments

var candidatesPath = "Evaluation/corpora/generation_eval_candidates_v1.json"
var outputDirOverride: String? = nil
var args = CommandLine.arguments.dropFirst().makeIterator()
while let arg = args.next() {
    switch arg {
    case "--candidates":
        guard let value = args.next() else { fail("--candidates requires a path argument") }
        candidatesPath = value
    case "--output-dir":
        guard let value = args.next() else { fail("--output-dir requires a path argument") }
        outputDirOverride = value
    default:
        fail("Unknown argument: \(arg)")
    }
}

// MARK: - Load fixtures

let candidatesURL = URL(fileURLWithPath: candidatesPath)
let promptsURL = URL(fileURLWithPath: "Evaluation/corpora/generation_eval_prompts_v1.json")

guard let candidatesData = try? Data(contentsOf: candidatesURL) else {
    fail("Could not read \(candidatesURL.path)")
}
guard let promptsData = try? Data(contentsOf: promptsURL) else {
    fail("Could not read \(promptsURL.path)")
}
let candidatesFixture = try JSONDecoder().decode(GenerationEvalCandidates.self, from: candidatesData)
let promptsFixture = try JSONDecoder().decode(GenerationEvalPrompts.self, from: promptsData)

// MARK: - Optional meaning-preservation embedder

// Deliberately does NOT fall back to `DeterministicSentenceEmbedder` when
// BGE isn't present: a hash-based stub embedding would produce cosine
// scores that look like signal but aren't (SemanticEval's own doc comment
// makes the same call for the same reason — see its "decorative space"
// note). Better to omit `meaningPreservationCosine` entirely than to hand a
// reviewer a misleading number.
let meaningPreservationEmbedder: (any SentenceEmbedder)?
do {
    meaningPreservationEmbedder = try CoreMLSentenceEmbedder(
        modelDirectory: URL(fileURLWithPath: "Models/BGE-small-en-v1.5")
    )
} catch {
    meaningPreservationEmbedder = nil
    print("Note: no BGE embedder at Models/BGE-small-en-v1.5; meaning_preservation_cosine will be omitted for every prompt.")
}

func meaningPreservationCosine(source: String, output: String) async -> Double? {
    guard let embedder = meaningPreservationEmbedder else { return nil }
    guard let embeddings = try? await embedder.encode([source, output]), embeddings.count == 2 else {
        return nil
    }
    return Double(embeddings[0].cosineSimilarity(to: embeddings[1])!)
}

// MARK: - Evaluate each candidate

var candidateResults: [GenerationEvalResult.CandidateResult] = []
var csvRows: [String] = []

func csvField(_ value: String) -> String {
    "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
}

let csvHeader = [
    "candidate", "prompt_id", "category", "first_token_latency", "generate_time",
    "tokens_per_second", "words_per_second", "word_count_ratio",
    "stop_reason", "decoder_loop_period", "decoder_loop_repeat_count",
    "prompt_echo_detected", "meaning_preservation_cosine",
    "prompt_text", "generated_text",
    "meaning_preserved", "grammar", "no_hallucination", "no_added_commentary",
    "conciseness", "instruction_followed",
].joined(separator: ",")

for candidate in candidatesFixture.candidates {
    let modelDirectory = URL(fileURLWithPath: "Models").appendingPathComponent(candidate.directory)
    guard FileManager.default.fileExists(atPath: modelDirectory.path) else {
        print("\(candidate.name): skipped — not downloaded (\(modelDirectory.path))")
        candidateResults.append(.init(
            name: candidate.name, directory: candidate.directory,
            status: "skipped: not downloaded", modelIdentifier: nil,
            coldLoadTime: nil, warmLoadTime: nil, peakRSSMB: nil, prompts: []
        ))
        continue
    }

    let configuration = GenerationConfiguration(
        extraEOSTokens: Set(candidate.extraEOSTokens),
        repetitionPenalty: candidate.repetitionPenalty
    )

    print("\(candidate.name): loading (cold)...")
    let coldStart = Date()
    let modelIdentifier: String
    do {
        let predictor = try await MLXNextWordPredictor(
            modelDirectory: modelDirectory, configuration: configuration
        )
        modelIdentifier = predictor.modelIdentifier
        // `predictor` (the cold instance) is deliberately captured down to
        // just its identifier and never referenced again — it previously
        // stayed alive (via a later `predictor.modelIdentifier` read after
        // the warm load) all the way through the RSS measurement below,
        // silently double-counting cold+warm model memory as one "peak."
    } catch {
        print("\(candidate.name): FAILED to load — \(error)")
        candidateResults.append(.init(
            name: candidate.name, directory: candidate.directory,
            status: "failed: \(error)", modelIdentifier: nil,
            coldLoadTime: nil, warmLoadTime: nil, peakRSSMB: nil, prompts: []
        ))
        continue
    }
    let coldLoadTime = Date().timeIntervalSince(coldStart)

    print("\(candidate.name): loading (warm)...")
    let warmStart = Date()
    // Only the warm instance is used for generation below, per the plan's
    // "keep the second instance" design; the cold instance above is no
    // longer reachable by this point, so it's already been released.
    let warmPredictor = try await MLXNextWordPredictor(
        modelDirectory: modelDirectory, configuration: configuration
    )
    let warmLoadTime = Date().timeIntervalSince(warmStart)
    let peakRSSMB = RSSMeasurement.residentSetSizeMB()

    print("\(candidate.name): cold=\(coldLoadTime)s warm=\(warmLoadTime)s rss=\(peakRSSMB)MB — running \(promptsFixture.prompts.count) prompts")

    var promptResults: [GenerationEvalResult.PromptResult] = []
    for prompt in promptsFixture.prompts {
        let metrics: GenerationMetrics
        do {
            metrics = try await warmPredictor.generateDetailed(
                prompt: prompt.text, maxTokens: 120, temperature: 0.7, cancellationID: UUID()
            )
        } catch {
            print("\(candidate.name)/\(prompt.id): generation failed — \(error)")
            continue
        }

        let ratio = wordCount(prompt.text) > 0
            ? Double(wordCount(metrics.text)) / Double(wordCount(prompt.text))
            : 0
        let cosine: Double? = rewriteShapedCategories.contains(prompt.category)
            ? await meaningPreservationCosine(source: prompt.text, output: metrics.text)
            : nil

        promptResults.append(.init(
            promptID: prompt.id, category: prompt.category,
            firstTokenLatency: metrics.promptTime, generateTime: metrics.generateTime,
            tokensPerSecond: metrics.tokensPerSecond, generatedText: metrics.text,
            wordCountRatio: ratio, meaningPreservationCosine: cosine,
            stopReason: metrics.stopReason, wordsPerSecond: metrics.wordsPerSecond,
            decoderLoopPeriod: metrics.decoderLoopPeriod,
            decoderLoopRepeatCount: metrics.decoderLoopRepeatCount,
            promptEchoDetected: metrics.promptEchoDetected
        ))

        csvRows.append([
            csvField(candidate.name), csvField(prompt.id), csvField(prompt.category),
            csvField(String(metrics.promptTime)), csvField(String(metrics.generateTime)),
            csvField(String(metrics.tokensPerSecond)), csvField(String(metrics.wordsPerSecond)),
            csvField(String(ratio)),
            csvField(metrics.stopReason), csvField(String(metrics.decoderLoopPeriod)),
            csvField(String(metrics.decoderLoopRepeatCount)),
            csvField(String(metrics.promptEchoDetected)),
            csvField(cosine.map { String($0) } ?? ""),
            csvField(prompt.text), csvField(metrics.text),
            "", "", "", "", "", "",
        ].joined(separator: ","))
    }

    candidateResults.append(.init(
        name: candidate.name, directory: candidate.directory, status: "evaluated",
        modelIdentifier: modelIdentifier,
        coldLoadTime: coldLoadTime, warmLoadTime: warmLoadTime, peakRSSMB: peakRSSMB,
        prompts: promptResults
    ))
}

// MARK: - Assemble + write

let result = GenerationEvalResult(
    schemaVersion: 1,
    provenance: .init(
        gitCommit: GitInfo.commitSHA(),
        device: RSSMeasurement.device(),
        macOSVersion: {
            let v = ProcessInfo.processInfo.operatingSystemVersion
            return "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
        }(),
        candidatesFixtureVersion: candidatesFixture.version,
        promptsFixtureVersion: promptsFixture.version
    ),
    candidates: candidateResults
)

let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
let data = try encoder.encode(result)

let outputDir: URL
if let override = outputDirOverride {
    outputDir = URL(fileURLWithPath: override)
} else {
    let dateFormatter = DateFormatter()
    dateFormatter.dateFormat = "yyyy-MM-dd"
    dateFormatter.timeZone = TimeZone(identifier: "UTC")
    let dateStamp = dateFormatter.string(from: Date())
    outputDir = URL(fileURLWithPath: "Evaluation").appendingPathComponent("\(dateStamp)-generation-eval")
}
try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

let jsonURL = outputDir.appendingPathComponent("data.json")
try data.write(to: jsonURL)
print("Wrote \(jsonURL.path)")

let csvURL = outputDir.appendingPathComponent("scoring-template.csv")
let csvContent = ([csvHeader] + csvRows).joined(separator: "\n") + "\n"
try csvContent.write(to: csvURL, atomically: true, encoding: .utf8)
print("Wrote \(csvURL.path)")
