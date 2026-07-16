import Foundation

/// Versioned candidate catalog —
/// `Evaluation/corpora/generation_eval_candidates_v1.json`. Deliberately not
/// wired into `BCILLM.MLXBackend`: these are exploration candidates, not
/// production-selectable backends. Promoting one to a real `MLXBackend`
/// case is a separate, later decision once the numbers are in.
struct GenerationEvalCandidates: Decodable {
    let version: Int
    let candidates: [Candidate]

    struct Candidate: Decodable {
        let name: String
        /// Leaf directory name under `Models/` — same convention as
        /// `MLXBackend.defaultModelName`.
        let directory: String
        let extraEOSTokens: [String]
        let repetitionPenalty: Float
    }
}

/// Versioned prompt corpus —
/// `Evaluation/corpora/generation_eval_prompts_v1.json`. Future corpora live
/// alongside this one under new filenames; this file is never overwritten
/// in place (same convention as `Evaluation/corpora/semantic_eval_v1.json`).
struct GenerationEvalPrompts: Decodable {
    let version: Int
    let prompts: [Prompt]

    struct Prompt: Decodable {
        let id: String
        let category: String
        let text: String
    }
}

/// Rewrite-shaped categories get a meaning-preservation cosine score;
/// `instruction-following` prompts don't (comparing "Say the word no" to
/// "No." via cosine similarity isn't a meaningful signal). A `Set` literal
/// rather than an enum: categories are data (defined in the JSON fixture,
/// extensible without a code change), this is just which of today's
/// categories opt into one particular derived metric.
let rewriteShapedCategories: Set<String> = [
    "filler-removal",
    "punctuation-restoration",
    "capitalization",
    "concise-rewrite",
    "command-reformulation",
    "technical-term-preservation",
]
