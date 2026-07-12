import Foundation

/// The canonical evidence artifact this tool produces — raw embeddings and
/// cosine-similarity relationships only. No projection, no clustering
/// metrics: those are derived, display/analysis choices that belong in
/// `Scripts/generate-semantic-eval-artifacts.py`, not baked into the
/// high-dimensional evidence itself.
struct SemanticEvalResult: Encodable {
    let schemaVersion: Int
    let provenance: Provenance
    let phrases: [PhraseEmbedding]
    let cosineMatrix: CosineMatrix
    let neighbors: [String: [NeighborScore]]
    let paraphrasePairs: [PairScore]
    let antonymPairs: [PairScore]
    let commandGroups: [String: CommandGroupResult]
    let crossCommandMeanSimilarity: Float
    let trajectories: [String: TrajectoryResult]

    struct Provenance: Encodable {
        let modelID: String
        let version: String
        let pooling: String
        let dimension: Int
        let gitCommit: String
        let evaluationCorpus: String
        let evaluationCorpusVersion: Int
        /// The seed `generate-semantic-eval-artifacts.py` must use for its
        /// Rademacher-projection port (`RandomProjectionProjector`'s
        /// default). Documented here as a contract between the two tools —
        /// this tool never invokes the projector itself.
        let projectionSeed: UInt64

        enum CodingKeys: String, CodingKey {
            case modelID = "model_id"
            case version, pooling, dimension
            case gitCommit = "git_commit"
            case evaluationCorpus = "evaluation_corpus"
            case evaluationCorpusVersion = "evaluation_corpus_version"
            case projectionSeed = "projection_seed"
        }
    }

    struct PhraseEmbedding: Encodable {
        let text: String
        let embedding: [Float]
    }

    struct CosineMatrix: Encodable {
        let texts: [String]
        let matrix: [[Float]]
    }

    struct NeighborScore: Encodable {
        let text: String
        let score: Float
    }

    struct PairScore: Encodable {
        let a: String
        let b: String
        let score: Float
    }

    struct CommandGroupResult: Encodable {
        let phrases: [String]
        let intraMeanSimilarity: Float

        enum CodingKeys: String, CodingKey {
            case phrases
            case intraMeanSimilarity = "intra_mean_similarity"
        }
    }

    struct TrajectoryResult: Encodable {
        let phrases: [String]
        let embeddings: [[Float]]
        let stepCosineSimilarities: [Float]

        enum CodingKeys: String, CodingKey {
            case phrases, embeddings
            case stepCosineSimilarities = "step_cosine_similarities"
        }
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version"
        case provenance, phrases
        case cosineMatrix = "cosine_matrix"
        case neighbors
        case paraphrasePairs = "paraphrase_pairs"
        case antonymPairs = "antonym_pairs"
        case commandGroups = "command_groups"
        case crossCommandMeanSimilarity = "cross_command_mean_similarity"
        case trajectories
    }
}
