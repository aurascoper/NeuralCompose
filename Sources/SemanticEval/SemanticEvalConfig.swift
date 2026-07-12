import Foundation

/// Versioned input corpus — `Evaluation/corpora/semantic_eval_v1.json`.
/// Future corpora (multilingual, commands-only, etc.) live alongside this
/// one under new filenames; this file is never overwritten in place.
struct SemanticEvalConfig: Decodable {
    let version: Int
    let corpus: [String]
    let queries: [String]
    let commandGroups: [String: [String]]
    let paraphrasePairs: [[String]]
    let antonymPairs: [[String]]
    let trajectories: [Trajectory]
    let topK: Int

    struct Trajectory: Decodable {
        let name: String
        let phrases: [String]
    }
}
