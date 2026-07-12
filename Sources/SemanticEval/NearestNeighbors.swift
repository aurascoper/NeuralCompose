import BCICore

/// Pure top-k cosine-similarity lookup — no numerical library needed beyond
/// what `Embedding.cosineSimilarity(to:)` already provides.
enum NearestNeighbors {
    struct Neighbor {
        let text: String
        let score: Float
    }

    static func topK(
        query: Embedding,
        corpusTexts: [String],
        corpusEmbeddings: [Embedding],
        k: Int
    ) -> [Neighbor] {
        let scored = zip(corpusTexts, corpusEmbeddings).map { text, embedding in
            Neighbor(text: text, score: query.cosineSimilarity(to: embedding))
        }
        return Array(scored.sorted { $0.score > $1.score }.prefix(k))
    }
}
