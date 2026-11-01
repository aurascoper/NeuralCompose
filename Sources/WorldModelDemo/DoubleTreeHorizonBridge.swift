import Foundation

/// A graph edge with stable, depth-independent endpoint identifiers.
public struct HorizonBridgeEdge: Sendable, Hashable, Codable {
    public let a: String
    public let b: String
    public let kind: Kind

    public enum Kind: String, Sendable, Codable {
        case upperTree
        case lowerTree
        case horizon
    }

    public init(_ a: String, _ b: String, kind: Kind) {
        self.a = min(a, b)
        self.b = max(a, b)
        self.kind = kind
    }

    public var key: String {
        "\(a)|\(b)"
    }
}

/// A vertex in the abstract double-tree graph. Coordinates are in a
/// normalized display coordinate system, not a spacetime metric.
public struct HorizonBridgeNode: Sendable, Codable, Identifiable, Equatable {
    public let id: String
    public let level: Int
    public let index: Int
    public let region: Region
    public let x: Double
    public let y: Double

    public enum Region: String, Sendable, Codable {
        case upper
        case horizon
        case lower
    }
}

public struct HorizonBridgeFrame: Sendable, Codable {
    public let index: Int
    public let title: String
    public let nodes: [HorizonBridgeNode]
    public let edges: [HorizonBridgeEdge]
    public let beta0: Int
    public let beta1: Int
    public let bridgeEdgeCount: Int
    public let bridgeEdgeKeys: [String]
}

public struct HorizonBridgeFixture: Sendable, Codable {
    public let depth: Int
    public let topology: Topology
    public let frames: [HorizonBridgeFrame]

    public enum Topology: String, Sendable, Codable, CaseIterable {
        /// Quotient corresponding upper and lower horizon leaves into 2^depth shared
        /// horizon vertices at y = 0 (matching Panel B of the reference figure).
        /// Contracting the 2^depth disjoint horizon links of `pairedHorizonLinks` is
        /// a cellular homotopy equivalence: V = 3*2^depth - 2, E = 4*2^depth - 4,
        /// beta0 = 1, beta1 = 2^depth - 1, and Tarjan bridge count = 0.
        case identifyLeaves
        /// Preserve both copies of the horizon leaves (at y = +0.25 and y = -0.25)
        /// and add one matching cross-edge per leaf pair (2^depth links total).
        /// Produces V = 4*2^depth - 2, E = 5*2^depth - 4, beta0 = 1,
        /// beta1 = 2^depth - 1, and Tarjan bridge count = 0.
        case pairedHorizonLinks
        /// Preserve both copies of the horizon leaves and connect only the primary
        /// leaf pair (index 0) with a single bridge edge. This joins the two trees
        /// without closing any cycles: V = 4*2^depth - 2, E = 4*2^depth - 3,
        /// beta0 = 1, beta1 = 0, and every edge is a Tarjan bridge (bridgeEdgeCount = E).
        case singleHorizonBridge
    }

    public var finalFrame: HorizonBridgeFrame { frames[frames.count - 1] }
}

public enum DoubleTreeHorizonBridgeError: Error, Equatable {
    case invalidDepth(Int)
}

/// Deterministic abstract graph fixture for the NeuralCompose research demo.
/// It is intentionally isolated from EEG, MLX, and the live generation path.
public enum DoubleTreeHorizonBridge {
    /// Half-width of the central horizon collar when upper and lower leaf sets
    /// are kept distinct (`pairedHorizonLinks` and `singleHorizonBridge`).
    public static let horizonCollarHalfHeight: Double = 0.25

    public static func make(
        depth: Int,
        topology: HorizonBridgeFixture.Topology = .pairedHorizonLinks
    ) throws -> HorizonBridgeFixture {
        guard (1...10).contains(depth) else {
            throw DoubleTreeHorizonBridgeError.invalidDepth(depth)
        }

        let separateLeafRows = (topology != .identifyLeaves)
        let upper = makeTree(depth: depth, inverted: false, prefix: "U", separateLeafRow: separateLeafRows)
        let lower = makeTree(depth: depth, inverted: true, prefix: "L", separateLeafRow: separateLeafRows)
        let horizonCount = 1 << depth

        let upperLeafIDs = (0..<horizonCount).map { "U-\(depth)-\($0)" }
        let lowerLeafIDs = (0..<horizonCount).map { "L-\(depth)-\($0)" }

        var finalNodes = upper.nodes + lower.nodes
        var finalEdges = upper.edges + lower.edges

        let finalTitle: String
        switch topology {
        case .identifyLeaves:
            // Identify lower horizon leaves with their upper partners at y = 0.
            let mapping = Dictionary(uniqueKeysWithValues: zip(lowerLeafIDs, upperLeafIDs))
            finalNodes = finalNodes.filter { !mapping.keys.contains($0.id) }
            finalEdges = finalEdges.map { edge in
                HorizonBridgeEdge(mapping[edge.a] ?? edge.a, mapping[edge.b] ?? edge.b, kind: edge.kind)
            }
            finalTitle = "Horizon leaves identified (quotient seam) : beta1 = \(horizonCount - 1)"
        case .pairedHorizonLinks:
            // Keep both leaf sets distinct across the horizon collar and join each matched pair.
            for i in 0..<horizonCount {
                finalEdges.append(HorizonBridgeEdge(upperLeafIDs[i], lowerLeafIDs[i], kind: .horizon))
            }
            finalTitle = "Paired horizon links (\(horizonCount) bridges) : beta1 = \(horizonCount - 1)"
        case .singleHorizonBridge:
            // Single contact between upper and lower trees: connected tree with beta1 = 0.
            finalEdges.append(HorizonBridgeEdge(upperLeafIDs[0], lowerLeafIDs[0], kind: .horizon))
            finalTitle = "Single horizon bridge (tree control) : beta1 = 0"
        }

        finalEdges = deduplicated(finalEdges)
        let upperFrame = makeFrame(
            index: 0,
            title: "Upper tree only : beta0 = 1, beta1 = 0",
            nodes: upper.nodes,
            edges: upper.edges
        )
        let lowerOnlyNodes = upper.nodes + lower.nodes
        let lowerOnlyEdges = upper.edges + lower.edges
        let lowerFrame = makeFrame(
            index: 1,
            title: "Add inverted tree (unbridged) : beta0 = 2, beta1 = 0",
            nodes: lowerOnlyNodes,
            edges: lowerOnlyEdges
        )
        let final = makeFrame(
            index: 2,
            title: finalTitle,
            nodes: finalNodes,
            edges: finalEdges
        )

        return HorizonBridgeFixture(depth: depth, topology: topology, frames: [upperFrame, lowerFrame, final])
    }

    private struct Tree {
        let nodes: [HorizonBridgeNode]
        let edges: [HorizonBridgeEdge]
    }

    private static func makeTree(depth: Int, inverted: Bool, prefix: String, separateLeafRow: Bool) -> Tree {
        var nodes: [HorizonBridgeNode] = []
        var edges: [HorizonBridgeEdge] = []
        for level in 0...depth {
            let count = 1 << level
            for index in 0..<count {
                let id = "\(prefix)-\(level)-\(index)"
                let x = (Double(index) + 0.5) / Double(count) * 2.0 - 1.0
                let baseSigned = Double(depth - level)
                let signed = separateLeafRow ? (baseSigned + horizonCollarHalfHeight) : baseSigned
                let y = inverted ? -signed : signed
                let region: HorizonBridgeNode.Region = level == depth ? .horizon : (inverted ? .lower : .upper)
                nodes.append(HorizonBridgeNode(id: id, level: level, index: index, region: region, x: x, y: y))
                if level < depth {
                    edges.append(HorizonBridgeEdge(id, "\(prefix)-\(level + 1)-\(2 * index)", kind: inverted ? .lowerTree : .upperTree))
                    edges.append(HorizonBridgeEdge(id, "\(prefix)-\(level + 1)-\(2 * index + 1)", kind: inverted ? .lowerTree : .upperTree))
                }
            }
        }
        return Tree(nodes: nodes, edges: edges)
    }

    private static func makeFrame(
        index: Int,
        title: String,
        nodes: [HorizonBridgeNode],
        edges: [HorizonBridgeEdge]
    ) -> HorizonBridgeFrame {
        let graph = Graph(nodes: nodes, edges: edges)
        let bridges = graph.bridgeEdges.sorted()
        return HorizonBridgeFrame(
            index: index,
            title: title,
            nodes: nodes.sorted { $0.id < $1.id },
            edges: edges.sorted { ($0.a, $0.b) < ($1.a, $1.b) },
            beta0: graph.componentCount,
            beta1: graph.edges.count - graph.nodes.count + graph.componentCount,
            bridgeEdgeCount: bridges.count,
            bridgeEdgeKeys: bridges
        )
    }

    private static func deduplicated(_ edges: [HorizonBridgeEdge]) -> [HorizonBridgeEdge] {
        var seen = Set<String>()
        return edges.filter {
            seen.insert($0.key).inserted
        }
    }

    private struct Graph {
        let nodes: [String: HorizonBridgeNode]
        let edges: [HorizonBridgeEdge]
        let adjacency: [String: [String]]

        init(nodes: [HorizonBridgeNode], edges: [HorizonBridgeEdge]) {
            self.nodes = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })
            self.edges = edges
            var adj: [String: [String]] = [:]
            for edge in edges {
                adj[edge.a, default: []].append(edge.b)
                adj[edge.b, default: []].append(edge.a)
            }
            self.adjacency = adj
        }

        var componentCount: Int {
            var visited = Set<String>()
            var count = 0
            for node in nodes.keys where !visited.contains(node) {
                count += 1
                var stack = [node]
                visited.insert(node)
                while let current = stack.popLast() {
                    for next in adjacency[current, default: []] where visited.insert(next).inserted {
                        stack.append(next)
                    }
                }
            }
            return count
        }

        /// Tarjan's O(V+E) bridge-finding algorithm.
        var bridgeEdges: Set<String> {
            var discovery: [String: Int] = [:]
            var low: [String: Int] = [:]
            var time = 0
            var bridges = Set<String>()

            func visit(_ node: String, parent: String?) {
                time += 1
                discovery[node] = time
                low[node] = time
                for next in adjacency[node, default: []] {
                    if next == parent { continue }
                    if discovery[next] == nil {
                        visit(next, parent: node)
                        low[node] = min(low[node] ?? time, low[next] ?? time)
                        if (low[next] ?? time) > (discovery[node] ?? time) {
                            bridges.insert(edgeKey(node, next))
                        }
                    } else {
                        low[node] = min(low[node] ?? time, discovery[next] ?? time)
                    }
                }
            }

            for node in nodes.keys.sorted() where discovery[node] == nil {
                visit(node, parent: nil)
            }
            return bridges
        }

        private func edgeKey(_ a: String, _ b: String) -> String {
            "\(min(a, b))|\(max(a, b))"
        }
    }
}
