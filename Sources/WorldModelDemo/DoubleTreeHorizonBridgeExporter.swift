import Foundation

/// Exports deterministic ChimeraX marker files plus exact graph metadata.
/// The .cmm file is the native ChimeraX marker-model XML format including
/// both `<marker>` vertices and `<link>` edges; graph edges are also retained
/// in the JSON metadata and emitted as a companion BILD cylinder file.
public enum DoubleTreeHorizonBridgeExporter {
    public static func write(_ fixture: HorizonBridgeFixture, to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for frame in fixture.frames {
            let cmm = markerXML(frame)
            let bild = bildEdges(frame)
            let json = try JSONEncoder.pretty.encode(frame)
            try cmm.write(to: directory.appendingPathComponent(String(format: "horizon-bridge-%02d.cmm", frame.index)), atomically: true, encoding: .utf8)
            try bild.write(to: directory.appendingPathComponent(String(format: "horizon-bridge-%02d-edges.bild", frame.index)), atomically: true, encoding: .utf8)
            try json.write(to: directory.appendingPathComponent(String(format: "horizon-bridge-%02d.json", frame.index)))
        }
        let readme = """
        # Double-tree horizon bridge export [MODEL ILLUSTRATION - RUNG_4_MODEL]

        Open a frame in ChimeraX with:
        ```
        open horizon-bridge-02.cmm
        open horizon-bridge-02-edges.bild
        ```

        The .cmm files contain both `<marker>` coordinates and `<link>` graph edges.
        The companion .bild files provide explicit cylinder geometry for ChimeraX ray-tracing.
        The JSON files contain the exact node/edge lists and calculated beta0, beta1, and Tarjan bridge counts.
        """
        try readme.write(to: directory.appendingPathComponent("README.txt"), atomically: true, encoding: .utf8)
    }

    public static func markerXML(_ frame: HorizonBridgeFrame) -> String {
        var lines = [
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?>",
            "<marker_set name=\"\(escape(frame.title))\">"
        ]
        var markerIDByNodeID: [String: Int] = [:]
        for (i, node) in frame.nodes.enumerated() {
            let markerID = i + 1
            markerIDByNodeID[node.id] = markerID
            let (r, g, b) = color(node.region)
            let radius = node.region == .horizon ? 0.085 : 0.065
            lines.append(
                String(
                    format: "  <marker id=\"%d\" x=\"%.5f\" y=\"%.5f\" z=\"0.00000\" r=\"%.3f\" g=\"%.3f\" b=\"%.3f\" radius=\"%.3f\" note=\"%@\"/>",
                    markerID, node.x, node.y, r, g, b, radius, escape(node.id)
                )
            )
        }
        for edge in frame.edges {
            guard let id1 = markerIDByNodeID[edge.a], let id2 = markerIDByNodeID[edge.b] else { continue }
            let (r, g, b) = edgeColor(edge.kind)
            let radius = edge.kind == .horizon ? 0.024 : 0.014
            lines.append(
                String(
                    format: "  <link id1=\"%d\" id2=\"%d\" r=\"%.3f\" g=\"%.3f\" b=\"%.3f\" radius=\"%.3f\"/>",
                    id1, id2, r, g, b, radius
                )
            )
        }
        lines.append("</marker_set>")
        return lines.joined(separator: "\n") + "\n"
    }

    public static func bildEdges(_ frame: HorizonBridgeFrame) -> String {
        let lookup = Dictionary(uniqueKeysWithValues: frame.nodes.map { ($0.id, $0) })
        var lines: [String] = []
        for edge in frame.edges {
            guard let a = lookup[edge.a], let b = lookup[edge.b] else { continue }
            let rgb = edge.kind == .horizon ? "1 0.75 0.12" : (edge.kind == .upperTree ? "0.2 0.65 1" : "0.75 0.35 0.95")
            let radius = edge.kind == .horizon ? 0.018 : 0.012
            lines.append(".color \(rgb)")
            lines.append(String(format: ".cylinder %.5f %.5f 0 %.5f %.5f 0 %.3f", a.x, a.y, b.x, b.y, radius))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func color(_ region: HorizonBridgeNode.Region) -> (Double, Double, Double) {
        switch region {
        case .upper: return (0.18, 0.62, 1.0)
        case .horizon: return (1.0, 0.74, 0.12)
        case .lower: return (0.72, 0.34, 0.96)
        }
    }

    private static func edgeColor(_ kind: HorizonBridgeEdge.Kind) -> (Double, Double, Double) {
        switch kind {
        case .upperTree: return (0.20, 0.65, 1.00)
        case .horizon: return (1.00, 0.75, 0.12)
        case .lowerTree: return (0.75, 0.35, 0.95)
        }
    }

    private static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
