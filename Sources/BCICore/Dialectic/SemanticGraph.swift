import Foundation

/// A bounded graph of everything the dialogue has said and heard, nodes linked
/// by embedding similarity. It is the substrate for *recurrence*: an old idea
/// can re-enter a later competition when the dialogue drifts back near it, so
/// the conversation can loop the way dreams do instead of only marching forward
/// through a linear trajectory.
///
/// Pure value type (a `struct` mutated in place by the owning actor). O(n·dim)
/// per insert with a small bounded `capacity`, so no index structure is needed.
public struct SemanticGraph: Sendable {

    public struct Node: Sendable, Equatable {
        public let id: Int
        public let text: String
        public let embedding: Embedding
        public let turnIndex: Int
        /// Whether this was a heard utterance or a spoken reply — kept for
        /// diagnostics; recurrence treats both alike.
        public let kind: Kind
        public enum Kind: String, Sendable, Equatable { case heard, reply }
    }

    public struct Edge: Sendable, Equatable {
        public let a: Int
        public let b: Int
        public let weight: Float   // normalized cosine in [0, 1]
    }

    public private(set) var nodes: [Node] = []
    public private(set) var edges: [Edge] = []

    private let capacity: Int
    private let edgeThreshold: Float
    private var nextID = 0

    /// - Parameters:
    ///   - capacity: max nodes retained; oldest are evicted with their edges.
    ///   - edgeThreshold: normalized-cosine `[0,1]` above which two nodes are
    ///     linked. 0.6 keeps only genuinely related ideas connected.
    public init(capacity: Int = 128, edgeThreshold: Float = 0.6) {
        self.capacity = max(1, capacity)
        self.edgeThreshold = edgeThreshold
    }

    /// Inserts a node, links it to every existing node above `edgeThreshold`,
    /// and evicts the oldest node(s) (and their edges) past `capacity`.
    @discardableResult
    public mutating func insert(text: String, embedding: Embedding,
                                turnIndex: Int, kind: Node.Kind) -> Node {
        let node = Node(id: nextID, text: text, embedding: embedding,
                        turnIndex: turnIndex, kind: kind)
        nextID += 1
        for existing in nodes {
            let w = DialecticalDynamics.normalized(embedding.cosineSimilarity(to: existing.embedding))
            if w >= edgeThreshold {
                edges.append(Edge(a: existing.id, b: node.id, weight: w))
            }
        }
        nodes.append(node)
        evictIfNeeded()
        return node
    }

    private mutating func evictIfNeeded() {
        while nodes.count > capacity {
            let removed = nodes.removeFirst().id
            edges.removeAll { $0.a == removed || $0.b == removed }
        }
    }

    /// Prior nodes most similar to `query`, most-similar first, filtered to
    /// `minSimilarity` (normalized `[0,1]`) and capped at `limit`.
    public func nearestPriorNodes(to query: Embedding, limit: Int,
                                  minSimilarity: Float = 0) -> [Node] {
        nodes
            .map { ($0, DialecticalDynamics.normalized(query.cosineSimilarity(to: $0.embedding))) }
            .filter { $0.1 >= minSimilarity }
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map { $0.0 }
    }
}
