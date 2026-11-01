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
}

/// A vertex in the abstract double-tree graph. Coordinates are in a
/// normalized display coordinate system, not a spacetime metric.
public struct HorizonBridgeNode: Sendable, Codable, Identifiable {
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
}

public struct HorizonBridgeFixture: Sendable, Codable {
    public let depth: Int
    public let topology: Topology
    public let frames: [HorizonBridgeFrame]

    public enum Topology: String, Sendable, Codable {
        /// Two trees share/identify the 2^depth horizon leaf vertices.
        /// This remains a tree (beta1=0); vertex identification alone
        /// does not create cycles.
        case identifyLeaves
        /// Preserve both copies of the horizon leaves and add one matching
        /// cross-edge per leaf pair. This produces a connected graph with
        /// beta1=2^depth-1.
        case pairedHorizonLinks
    }

    public var finalFrame: HorizonBridgeFrame { frames[frames.count - 1] }
}

public enum DoubleTreeHorizonBridgeError: Error, Equatable {
    case invalidDepth(Int)
}

/// Deterministic abstract graph fixture for the NeuralCompose research demo.
/// It is intentionally isolated from EEG, MLX, and the live generation path.
public enum DoubleTreeHorizonBridge {
    public static func make(depth: Int, topology: HorizonBridgeFixture.Topology = .pairedHorizonLinks) throws -> HorizonBridgeFixture {
        guard (1...10).contains(depth) else {
            throw DoubleTreeHorizonBridgeError.invalidDepth(depth)
        }

        let upper = makeTree(depth: depth, inverted: false, prefix: "U")
        let lower = makeTree(depth: depth, inverted: true, prefix: "L")
        let horizonCount = 1 << depth

        let upperLeafIDs = (0..<horizonCount).map { "U-\(depth)-\($0)" }
        let lowerLeafIDs = (0..<horizonCount).map { "L-\(depth)-\($0)" }

        var finalNodes = upper.nodes + lower.nodes
        var finalEdges = upper.edges + lower.edges

        switch topology {
        case .identifyLeaves:
            // Identify lower horizon leaves with their upper partners.
            let mapping = Dictionary(uniqueKeysWithValues: zip(lowerLeafIDs, upperLeafIDs))
            finalNodes = finalNodes.filter { !mapping.keys.contains($0.id) }
            finalEdges = finalEdges.map { edge in
                HorizonBridgeEdge(mapping[edge.a] ?? edge.a, mapping[edge.b] ?? edge.b, kind: edge.kind)
            }
            // The surviving upper horizon vertices already remain in finalNodes.
        case .pairedHorizonLinks:
            // This edge set is precisely what creates cycles. It keeps the
            // two leaf sets distinct and joins each matched pair once.
            for i in 0..<horizonCount {
                finalEdges.append(HorizonBridgeEdge(upperLeafIDs[i], lowerLeafIDs[i], kind: .horizon))
            }
        }

        finalEdges = deduplicated(finalEdges)
        let upperFrame = makeFrame(index: 0, title: "Upper tree · beta1 = 0", nodes: upper.nodes, edges: upper.edges)
        let lowerOnlyNodes = upper.nodes + lower.nodes
        let lowerOnlyEdges = upper.edges + lower.edges
        let lowerFrame = makeFrame(index: 1, title: "Add inverted tree · disconnected components", nodes: lowerOnlyNodes, edges: lowerOnlyEdges)
        let finalTitle = topology == .pairedHorizonLinks ? "Horizon linked · calculated cycle rank" : "Horizon leaves identified · still a tree"
        let final = makeFrame(index: 2, title: finalTitle, nodes: finalNodes, edges: finalEdges)

        return HorizonBridgeFixture(depth: depth, topology: topology, frames: [upperFrame, lowerFrame, final])
    }

    private struct Tree {
        let nodes: [HorizonBridgeNode]
        let edges: [HorizonBridgeEdge]
    }

    private static func makeTree(depth: Int, inverted: Bool, prefix: String) -> Tree {
        var nodes: [HorizonBridgeNode] = []
        var edges: [HorizonBridgeEdge] = []
        for level in 0...depth {
            let count = 1 << level
            for index in 0..<count {
                let id = "\(prefix)-\(level)-\(index)"
                let x = (Double(index) + 0.5) / Double(count) * 2.0 - 1.0
                let signed = Double(depth - level)
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

    private static func makeFrame(index: Int, title: String, nodes: [HorizonBridgeNode], edges: [HorizonBridgeEdge]) -> HorizonBridgeFrame {
        let graph = Graph(nodes: nodes, edges: edges)
        return HorizonBridgeFrame(index: index, title: title, nodes: nodes.sorted { $0.id < $1.id },
                                  edges: edges.sorted { ($0.a, $0.b) < ($1.a, $1.b) },
                                  beta0: graph.componentCount,
                                  beta1: graph.edges.count - graph.nodes.count + graph.componentCount,
                                  bridgeEdgeCount: graph.bridgeEdges.count)
    }

    private static func deduplicated(_ edges: [HorizonBridgeEdge]) -> [HorizonBridgeEdge] {
        var seen = Set<String>()
        return edges.filter {
            let key = "\($0.a)|\($0.b)"
            return seen.insert(key).inserted
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
