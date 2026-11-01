import XCTest
@testable import WorldModelDemo

final class DoubleTreeHorizonBridgeTests: XCTestCase {
    func testPairedHorizonLinksHaveExpectedCycleRankForDepthsOneThroughSix() throws {
        for depth in 1...6 {
            let fixture = try DoubleTreeHorizonBridge.make(depth: depth, topology: .pairedHorizonLinks)
            let frame = fixture.finalFrame
            let horizonLinks = 1 << depth
            XCTAssertEqual(frame.beta0, 1, "depth=\(depth)")
            XCTAssertEqual(frame.beta1, horizonLinks - 1, "depth=\(depth)")
            XCTAssertEqual(frame.edges.count - frame.nodes.count + frame.beta0, frame.beta1)
        }
    }

    func testIdentifyingLeavesDoesNotCreateCycles() throws {
        for depth in 1...6 {
            let fixture = try DoubleTreeHorizonBridge.make(depth: depth, topology: .identifyLeaves)
            XCTAssertEqual(fixture.finalFrame.beta0, 1)
            XCTAssertEqual(fixture.finalFrame.beta1, 0)
        }
    }

    func testTarjanBridgeCountMatchesEdgeRemovalOracle() throws {
        let fixture = try DoubleTreeHorizonBridge.make(depth: 4)
        let frame = fixture.finalFrame
        let expected = frame.edges.filter { edge in
            Self.componentCount(nodes: frame.nodes, edges: frame.edges.filter { $0 != edge }) > frame.beta0
        }.count
        XCTAssertEqual(frame.bridgeEdgeCount, expected)
    }

    func testStableIDsAndEdges() throws {
        let a = try DoubleTreeHorizonBridge.make(depth: 3)
        let b = try DoubleTreeHorizonBridge.make(depth: 3)
        XCTAssertEqual(a.finalFrame.nodes.map(\.id), b.finalFrame.nodes.map(\.id))
        XCTAssertEqual(a.finalFrame.edges, b.finalFrame.edges)
    }

    func testInvalidDepthRejected() {
        XCTAssertThrowsError(try DoubleTreeHorizonBridge.make(depth: 0))
        XCTAssertThrowsError(try DoubleTreeHorizonBridge.make(depth: 11))
    }

    private static func componentCount(nodes: [HorizonBridgeNode], edges: [HorizonBridgeEdge]) -> Int {
        var adjacency: [String: [String]] = [:]
        for e in edges {
            adjacency[e.a, default: []].append(e.b)
            adjacency[e.b, default: []].append(e.a)
        }
        var visited = Set<String>()
        var count = 0
        for node in nodes where !visited.contains(node.id) {
            count += 1
            var stack = [node.id]
            visited.insert(node.id)
            while let current = stack.popLast() {
                for next in adjacency[current, default: []] where visited.insert(next).inserted {
                    stack.append(next)
                }
            }
        }
        return count
    }
}
