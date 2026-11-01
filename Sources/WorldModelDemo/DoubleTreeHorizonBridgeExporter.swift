import Foundation

/// Exports deterministic ChimeraX marker files plus exact graph metadata.
/// The .cmm file is the native ChimeraX marker-model format; graph edges are
/// retained in the JSON metadata and emitted as a companion BILD file.
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
        # Double-tree horizon bridge export

        Open a frame in ChimeraX with:
        ```
        open horizon-bridge-02.cmm
        open horizon-bridge-02-edges.bild
        ```

        The .cmm files contain marker coordinates; the companion .bild files draw graph edges.
        The JSON files contain the exact node/edge lists and calculated beta0/beta1/bridge counts.
        """
        try readme.write(to: directory.appendingPathComponent("README.txt"), atomically: true, encoding: .utf8)
    }

    private static func markerXML(_ frame: HorizonBridgeFrame) -> String {
        var lines = ["<?xml version=\"1.0\" encoding=\"UTF-8\"?>",
                     "<marker_set name=\"\(escape(frame.title))\">"]
        for (i, node) in frame.nodes.enumerated() {
            let (r, g, b) = color(node.region)
            lines.append(String(format: "  <marker id=\"%d\" x=\"%.5f\" y=\"%.5f\" z=\"0.00000\" r=\"%.3f\" g=\"%.3f\" b=\"%.3f\" radius=\"0.075\"/>",
                                i + 1, node.x, node.y, r, g, b))
        }
        lines.append("</marker_set>")
        return lines.joined(separator: "\n") + "\n"
    }

    private static func bildEdges(_ frame: HorizonBridgeFrame) -> String {
        let lookup = Dictionary(uniqueKeysWithValues: frame.nodes.map { ($0.id, $0) })
        var lines: [String] = []
        for edge in frame.edges {
            guard let a = lookup[edge.a], let b = lookup[edge.b] else { continue }
            let rgb = edge.kind == .horizon ? "1 0.75 0.12" : (edge.kind == .upperTree ? "0.2 0.65 1" : "0.75 0.35 0.95")
            lines.append(".color \(rgb)")
            lines.append(String(format: ".cylinder %.5f %.5f 0 %.5f %.5f 0 0.012", a.x, a.y, b.x, b.y))
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

    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }
}

private extension JSONEncoder {
    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}
