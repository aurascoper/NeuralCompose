import BCICore
import Foundation

// Stage 3.1 first run target: the deterministic stub, to validate the
// harness end-to-end before any Core ML conversion work happens. The next
// real target is BGE-small-en-v1.5 (Stage 3.2), which will construct a
// `CoreMLSentenceEmbedder` here instead — `BenchmarkRunner` doesn't change.
let embedder = DeterministicSentenceEmbedder(dimension: 384, seed: 0)
let result = try await BenchmarkRunner.run(embedder: embedder, runtime: "stub")

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
