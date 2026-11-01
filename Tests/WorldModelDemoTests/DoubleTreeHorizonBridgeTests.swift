import XCTest
@testable import WorldModelDemo

final class DoubleTreeHorizonBridgeTests: XCTestCase {
    func testPairedHorizonLinksHaveExpectedCycleRankForDepthsOneThroughSix() throws {
        for depth in 1...6 {
            let fixture = try DoubleTreeHorizonBridge.make(depth: depth, topology: .pairedHorizonLinks)
            let frame = fixture.finalFrame
            let horizonLinks = 1 << depth
            XCTAssertEqual(frame.nodes.count, 4 * horizonLinks - 2, "depth=\(depth)")
            XCTAssertEqual(frame.edges.count, 5 * horizonLinks - 4, "depth=\(depth)")
            XCTAssertEqual(frame.beta0, 1, "depth=\(depth)")
            XCTAssertEqual(frame.beta1, horizonLinks - 1, "depth=\(depth)")
            XCTAssertEqual(frame.bridgeEdgeCount, 0, "depth=\(depth)")
            XCTAssertEqual(frame.edges.count - frame.nodes.count + frame.beta0, frame.beta1)
        }
    }

    func testIdentifyLeavesHomotopyEquivalenceCreatesMatchingCycleRank() throws {
        for depth in 1...6 {
            let fixture = try DoubleTreeHorizonBridge.make(depth: depth, topology: .identifyLeaves)
            let frame = fixture.finalFrame
            let horizonCount = 1 << depth
            XCTAssertEqual(frame.nodes.count, 3 * horizonCount - 2, "depth=\(depth)")
            XCTAssertEqual(frame.edges.count, 4 * horizonCount - 4, "depth=\(depth)")
            XCTAssertEqual(frame.beta0, 1, "depth=\(depth)")
            XCTAssertEqual(frame.beta1, horizonCount - 1, "depth=\(depth)")
            XCTAssertEqual(frame.bridgeEdgeCount, 0, "depth=\(depth)")
            XCTAssertEqual(frame.edges.count - frame.nodes.count + frame.beta0, frame.beta1)
        }
    }

    func testSingleHorizonBridgeRemainsTreeWithZeroCycles() throws {
        for depth in 1...6 {
            let fixture = try DoubleTreeHorizonBridge.make(depth: depth, topology: .singleHorizonBridge)
            let frame = fixture.finalFrame
            let horizonCount = 1 << depth
            XCTAssertEqual(frame.nodes.count, 4 * horizonCount - 2, "depth=\(depth)")
            XCTAssertEqual(frame.edges.count, 4 * horizonCount - 3, "depth=\(depth)")
            XCTAssertEqual(frame.beta0, 1, "depth=\(depth)")
            XCTAssertEqual(frame.beta1, 0, "depth=\(depth)")
            XCTAssertEqual(frame.bridgeEdgeCount, frame.edges.count, "depth=\(depth)")
        }
    }

    func testTarjanBridgeCountMatchesEdgeRemovalOracleAcrossTopologiesAndFrames() throws {
        for topology in HorizonBridgeFixture.Topology.allCases {
            let fixture = try DoubleTreeHorizonBridge.make(depth: 4, topology: topology)
            for frame in fixture.frames {
                let expected = frame.edges.filter { edge in
                    Self.componentCount(nodes: frame.nodes, edges: frame.edges.filter { $0 != edge }) > frame.beta0
                }.count
                XCTAssertEqual(frame.bridgeEdgeCount, expected, "topology=\(topology.rawValue), frame=\(frame.index)")
            }
        }
    }

    func testExporterEmitsMarkersLinksAndPositiveLengthCylinders() throws {
        let fixture = try DoubleTreeHorizonBridge.make(depth: 3, topology: .pairedHorizonLinks)
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DoubleTreeHorizonBridgeTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        try DoubleTreeHorizonBridgeExporter.write(fixture, to: tempDir)

        let cmmURL = tempDir.appendingPathComponent("horizon-bridge-02.cmm")
        let bildURL = tempDir.appendingPathComponent("horizon-bridge-02-edges.bild")
        let jsonURL = tempDir.appendingPathComponent("horizon-bridge-02.json")

        let cmmText = try String(contentsOf: cmmURL, encoding: .utf8)
        XCTAssertTrue(cmmText.contains("<marker id=\"1\""))
        XCTAssertTrue(cmmText.contains("<link id1="))

        let bildText = try String(contentsOf: bildURL, encoding: .utf8)
        let cylinderLines = bildText.split(separator: "\n").filter { $0.hasPrefix(".cylinder ") }
        XCTAssertEqual(cylinderLines.count, fixture.finalFrame.edges.count)
        for line in cylinderLines {
            let parts = line.split(separator: " ")
            XCTAssertEqual(parts.count, 8)
            let x1 = Double(parts[1]) ?? 0
            let y1 = Double(parts[2]) ?? 0
            let x2 = Double(parts[4]) ?? 0
            let y2 = Double(parts[5]) ?? 0
            let length = hypot(x2 - x1, y2 - y1)
            XCTAssertGreaterThan(length, 0.001, "Degenerate zero-length cylinder in BILD: \(line)")
        }

        let jsonData = try Data(contentsOf: jsonURL)
        let decoded = try JSONDecoder().decode(HorizonBridgeFrame.self, from: jsonData)
        XCTAssertEqual(decoded.beta0, 1)
        XCTAssertEqual(decoded.beta1, 7)
        XCTAssertEqual(decoded.bridgeEdgeCount, 0)
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
