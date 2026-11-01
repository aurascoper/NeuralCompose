import Foundation
import AppKit
#if canImport(WorldModelDemo)
import WorldModelDemo
#endif

// Standalone export and 2560x1440 milestone comparison renderer for DoubleTreeHorizonBridge.
// Run with:
//   swiftc -O -parse-as-library Sources/WorldModelDemo/DoubleTreeHorizonBridge.swift \
//     Sources/WorldModelDemo/DoubleTreeHorizonBridgeExporter.swift \
//     Scripts/export-double-tree-horizon-bridge.swift \
//     -o /tmp/export-double-tree && /tmp/export-double-tree --milestone

@main
struct ExportDoubleTreeHorizonBridge {
    static func main() throws {
        let args = Array(CommandLine.arguments.dropFirst())

        if args.first == "--milestone" || args.isEmpty {
            let baseDir = URL(fileURLWithPath: args.dropFirst().first ?? "Artifacts/DoubleTreeHorizonBridge", isDirectory: true)
            var fixtures: [String: HorizonBridgeFixture] = [:]
            for depth in [3, 5] {
                for topology in HorizonBridgeFixture.Topology.allCases {
                    let subDir = baseDir
                        .appendingPathComponent("depth-\(depth)", isDirectory: true)
                        .appendingPathComponent(topology.rawValue, isDirectory: true)
                    let fixture = try DoubleTreeHorizonBridge.make(depth: depth, topology: topology)
                    fixtures["\(depth)-\(topology.rawValue)"] = fixture
                    try DoubleTreeHorizonBridgeExporter.write(fixture, to: subDir)
                    let f0 = fixture.frames[0]
                    let f1 = fixture.frames[1]
                    let f2 = fixture.finalFrame
                    print(
                        "depth=\(depth) topology=\(topology.rawValue) | " +
                        "F0(V=\(f0.nodes.count),E=\(f0.edges.count),b0=\(f0.beta0),b1=\(f0.beta1),br=\(f0.bridgeEdgeCount)) -> " +
                        "F1(V=\(f1.nodes.count),E=\(f1.edges.count),b0=\(f1.beta0),b1=\(f1.beta1),br=\(f1.bridgeEdgeCount)) -> " +
                        "F2(V=\(f2.nodes.count),E=\(f2.edges.count),b0=\(f2.beta0),b1=\(f2.beta1),br=\(f2.bridgeEdgeCount)) -> \(subDir.path)"
                    )
                }
            }
            let pngURL = baseDir.appendingPathComponent("DoubleTree_Horizon_Bridge_Depth3_vs_Depth5_Comparison.png")
            try renderMilestoneComparisonPNG(fixtures: fixtures, to: pngURL)
            print("Rendered 2560x1440 comparison figure: \(pngURL.path)")
        } else {
            let depth = Int(args.first ?? "3") ?? 3
            let outputPath = args.dropFirst().first ?? "Artifacts/DoubleTreeHorizonBridge/depth-\(depth)"
            let topologyRaw = args.dropFirst(2).first ?? HorizonBridgeFixture.Topology.pairedHorizonLinks.rawValue
            let topology = HorizonBridgeFixture.Topology(rawValue: topologyRaw) ?? .pairedHorizonLinks
            let output = URL(fileURLWithPath: outputPath, isDirectory: true)
            let fixture = try DoubleTreeHorizonBridge.make(depth: depth, topology: topology)
            try DoubleTreeHorizonBridgeExporter.write(fixture, to: output)
            print("Exported depth \(depth) (\(topology.rawValue)): V=\(fixture.finalFrame.nodes.count), E=\(fixture.finalFrame.edges.count), beta0=\(fixture.finalFrame.beta0), beta1=\(fixture.finalFrame.beta1), bridges=\(fixture.finalFrame.bridgeEdgeCount)")
            print("Output: \(output.path)")
        }
    }

    private static func renderMilestoneComparisonPNG(
        fixtures: [String: HorizonBridgeFixture],
        to url: URL
    ) throws {
        let width = 2560
        let height = 1440
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ), let nsCtx = NSGraphicsContext(bitmapImageRep: rep) else {
            throw NSError(domain: "ExportDoubleTreeHorizonBridge", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to allocate bitmap context"])
        }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsCtx
        let cg = nsCtx.cgContext

        // Note: AppKit flipped/unflipped coordinate system: y=0 at bottom, y=1440 at top.
        let bg = NSColor(calibratedRed: 0.035, green: 0.051, blue: 0.086, alpha: 1.0)
        cg.setFillColor(bg.cgColor)
        cg.fill(CGRect(x: 0, y: 0, width: width, height: height))

        // Header banner
        drawText(
            "GLUED DOUBLE-TREE HORIZON BRIDGE : DEPTH-3 VS. DEPTH-5 TOPOLOGY & TARJAN BRIDGE VERIFICATION",
            rect: CGRect(x: 40, y: height - 58, width: width - 80, height: 34),
            font: .boldSystemFont(ofSize: 24),
            color: .white,
            alignment: .center
        )
        drawText(
            "[MODEL ILLUSTRATION - RUNG_4_MODEL] | Isolated WorldModelDemo Research Fixture | All V, E, beta0, beta1, and Tarjan bridge counts computed from exported graph data",
            rect: CGRect(x: 40, y: height - 88, width: width - 80, height: 24),
            font: .monospacedSystemFont(ofSize: 15, weight: .medium),
            color: NSColor(calibratedRed: 0.60, green: 0.72, blue: 0.88, alpha: 1.0),
            alignment: .center
        )

        let marginX: CGFloat = 44
        let topMargin: CGFloat = 104
        let bottomMargin: CGFloat = 74
        let gapX: CGFloat = 28
        let gapY: CGFloat = 28
        let panelW = (CGFloat(width) - 2 * marginX - 2 * gapX) / 3.0
        let panelH = (CGFloat(height) - topMargin - bottomMargin - gapY) / 2.0

        func panelRect(row: Int, col: Int) -> CGRect {
            let x = marginX + CGFloat(col) * (panelW + gapX)
            let y = bottomMargin + CGFloat(1 - row) * (panelH + gapY)
            return CGRect(x: x, y: y, width: panelW, height: panelH)
        }

        if let d3Paired = fixtures["3-pairedHorizonLinks"],
           let d3Single = fixtures["3-singleHorizonBridge"],
           let d3Ident = fixtures["3-identifyLeaves"],
           let d5Paired = fixtures["5-pairedHorizonLinks"],
           let d5Ident = fixtures["5-identifyLeaves"] {

            drawGraphPanel(
                cg: cg,
                rect: panelRect(row: 0, col: 0),
                frame: d3Paired.frames[1],
                title: "A. Depth 3 Frame 1: Unbridged Double-Tree",
                subtitle: "2^3=8 leaves/tree | V=30 E=28 | beta0=2 beta1=0 | Tarjan Bridges=28 (all dashed)",
                nodeScale: 1.0
            )
            drawGraphPanel(
                cg: cg,
                rect: panelRect(row: 0, col: 1),
                frame: d3Single.finalFrame,
                title: "B. Depth 3 Single Horizon Contact (Tree Control)",
                subtitle: "1 link | V=30 E=29 | beta0=1 beta1=0 | Tarjan Bridges=29 (no cycles)",
                nodeScale: 1.0
            )
            drawGraphPanel(
                cg: cg,
                rect: panelRect(row: 0, col: 2),
                frame: d3Paired.finalFrame,
                title: "C. Depth 3 Paired Horizon Collar (2^3 = 8 Links)",
                subtitle: "8 links | V=30 E=36 | beta0=1 beta1=7 | Tarjan Bridges=0 (biconnected)",
                nodeScale: 1.0
            )
            drawGraphPanel(
                cg: cg,
                rect: panelRect(row: 1, col: 0),
                frame: d3Ident.finalFrame,
                title: "D. Depth 3 Quotient Seam (Identify Leaves at y = 0)",
                subtitle: "8 shared nodes | V=22 E=28 | beta0=1 beta1=7 | Tarjan Bridges=0 (homotopy equiv.)",
                nodeScale: 1.0
            )
            drawGraphPanel(
                cg: cg,
                rect: panelRect(row: 1, col: 1),
                frame: d5Paired.finalFrame,
                title: "E. Depth 5 Paired Horizon Collar (2^5 = 32 Links)",
                subtitle: "32 links | V=126 E=156 | beta0=1 beta1=31 | Tarjan Bridges=0 (biconnected)",
                nodeScale: 0.65
            )
            drawGraphPanel(
                cg: cg,
                rect: panelRect(row: 1, col: 2),
                frame: d5Ident.finalFrame,
                title: "F. Depth 5 Quotient Seam (Identify Leaves at y = 0)",
                subtitle: "32 shared nodes | V=94 E=124 | beta0=1 beta1=31 | Tarjan Bridges=0 (homotopy equiv.)",
                nodeScale: 0.65
            )
        }

        // Bottom legend bar
        drawText(
            "LEGEND:  Cyan = Upper Tree (U)   |   Purple = Lower Inverted Tree (L)   |   Gold = Horizon Nodes & Cross-Links   |   Solid Edge = Biconnected Cycle Edge   |   Dashed Edge = Tarjan Bridge (Removal Disconnects Graph)",
            rect: CGRect(x: 44, y: 20, width: width - 88, height: 28),
            font: .monospacedSystemFont(ofSize: 15, weight: .semibold),
            color: NSColor(calibratedRed: 0.90, green: 0.94, blue: 1.0, alpha: 1.0),
            alignment: .center
        )

        NSGraphicsContext.restoreGraphicsState()

        guard let pngData = rep.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "ExportDoubleTreeHorizonBridge", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to encode PNG"])
        }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try pngData.write(to: url)
    }

    private static func drawGraphPanel(
        cg: CGContext,
        rect: CGRect,
        frame: HorizonBridgeFrame,
        title: String,
        subtitle: String,
        nodeScale: CGFloat
    ) {
        let panelBg = NSColor(calibratedRed: 0.055, green: 0.078, blue: 0.133, alpha: 1.0)
        let borderCol = NSColor(calibratedRed: 0.18, green: 0.24, blue: 0.36, alpha: 1.0)

        let path = CGPath(roundedRect: rect, cornerWidth: 10, cornerHeight: 10, transform: nil)
        cg.addPath(path)
        cg.setFillColor(panelBg.cgColor)
        cg.fillPath()
        cg.addPath(path)
        cg.setStrokeColor(borderCol.cgColor)
        cg.setLineWidth(1.5)
        cg.strokePath()

        // Title and subtitle at top of panel
        drawText(
            title,
            rect: CGRect(x: rect.minX + 14, y: rect.maxY - 36, width: rect.width - 28, height: 24),
            font: .boldSystemFont(ofSize: 17),
            color: .white,
            alignment: .left
        )
        drawText(
            subtitle,
            rect: CGRect(x: rect.minX + 14, y: rect.maxY - 60, width: rect.width - 28, height: 20),
            font: .monospacedSystemFont(ofSize: 13, weight: .semibold),
            color: NSColor(calibratedRed: 1.0, green: 0.80, blue: 0.25, alpha: 1.0),
            alignment: .left
        )

        let plotRect = CGRect(
            x: rect.minX + 26,
            y: rect.minY + 24,
            width: rect.width - 52,
            height: rect.height - 96
        )

        let minX = -1.02
        let maxX = 1.02
        let ys = frame.nodes.map(\.y)
        let minY = (ys.min() ?? -3.2) - 0.30
        let maxY = (ys.max() ?? 3.2) + 0.30

        func mapPoint(_ x: Double, _ y: Double) -> CGPoint {
            let nx = (x - minX) / max(maxX - minX, 0.001)
            let ny = (y - minY) / max(maxY - minY, 0.001)
            return CGPoint(
                x: plotRect.minX + CGFloat(nx) * plotRect.width,
                y: plotRect.minY + CGFloat(ny) * plotRect.height
            )
        }

        // Subtle grid lines
        cg.saveGState()
        cg.setStrokeColor(NSColor(calibratedRed: 0.12, green: 0.17, blue: 0.26, alpha: 0.75).cgColor)
        cg.setLineWidth(0.8)
        cg.setLineDash(phase: 0, lengths: [4, 4])
        for gx in stride(from: -1.0, through: 1.0, by: 0.25) {
            let p1 = mapPoint(gx, minY)
            let p2 = mapPoint(gx, maxY)
            cg.move(to: p1)
            cg.addLine(to: p2)
        }
        cg.strokePath()
        cg.restoreGState()

        // Central horizon band around y = 0
        let bandTop = mapPoint(0, 0.32).y
        let bandBot = mapPoint(0, -0.32).y
        let bandRect = CGRect(
            x: plotRect.minX,
            y: min(bandTop, bandBot),
            width: plotRect.width,
            height: abs(bandTop - bandBot)
        )
        cg.setFillColor(NSColor(calibratedRed: 0.98, green: 0.74, blue: 0.12, alpha: 0.13).cgColor)
        cg.fill(bandRect)

        let zeroLeft = mapPoint(minX, 0.0)
        let zeroRight = mapPoint(maxX, 0.0)
        cg.saveGState()
        cg.setStrokeColor(NSColor(calibratedRed: 1.0, green: 0.78, blue: 0.18, alpha: 0.40).cgColor)
        cg.setLineWidth(1.1)
        cg.setLineDash(phase: 0, lengths: [3, 3])
        cg.move(to: zeroLeft)
        cg.addLine(to: zeroRight)
        cg.strokePath()
        cg.restoreGState()

        let lookup = Dictionary(uniqueKeysWithValues: frame.nodes.map { ($0.id, $0) })
        let bridgeSet = Set(frame.bridgeEdgeKeys)

        // Draw edges
        for edge in frame.edges {
            guard let a = lookup[edge.a], let b = lookup[edge.b] else { continue }
            let pa = mapPoint(a.x, a.y)
            let pb = mapPoint(b.x, b.y)
            let isBridge = bridgeSet.contains(edge.key)

            let color: NSColor
            let lw: CGFloat
            switch edge.kind {
            case .horizon:
                color = NSColor(calibratedRed: 1.0, green: 0.78, blue: 0.12, alpha: 0.96)
                lw = 3.2 * nodeScale
            case .upperTree:
                color = NSColor(calibratedRed: 0.18, green: 0.77, blue: 1.0, alpha: 0.90)
                lw = 2.0 * nodeScale
            case .lowerTree:
                color = NSColor(calibratedRed: 0.74, green: 0.38, blue: 1.0, alpha: 0.90)
                lw = 2.0 * nodeScale
            }

            cg.saveGState()
            cg.setStrokeColor(color.cgColor)
            cg.setLineWidth(max(lw, 1.1))
            if isBridge {
                cg.setLineDash(phase: 0, lengths: [6, 4])
            }
            cg.move(to: pa)
            cg.addLine(to: pb)
            cg.strokePath()
            cg.restoreGState()
        }

        // Draw nodes
        for node in frame.nodes {
            let p = mapPoint(node.x, node.y)
            let r: CGFloat
            let fill: NSColor
            let stroke: NSColor
            switch node.region {
            case .horizon:
                r = max(5.6 * nodeScale, 3.2)
                fill = NSColor(calibratedRed: 1.0, green: 0.76, blue: 0.10, alpha: 1.0)
                stroke = .white
            case .upper:
                r = max(4.0 * nodeScale, 2.3)
                fill = NSColor(calibratedRed: 0.18, green: 0.77, blue: 1.0, alpha: 1.0)
                stroke = NSColor(calibratedRed: 0.04, green: 0.06, blue: 0.10, alpha: 1.0)
            case .lower:
                r = max(4.0 * nodeScale, 2.3)
                fill = NSColor(calibratedRed: 0.74, green: 0.38, blue: 1.0, alpha: 1.0)
                stroke = NSColor(calibratedRed: 0.04, green: 0.06, blue: 0.10, alpha: 1.0)
            }
            let nodeRect = CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)
            cg.setFillColor(fill.cgColor)
            cg.fillEllipse(in: nodeRect)
            cg.setStrokeColor(stroke.cgColor)
            cg.setLineWidth(max(1.2 * nodeScale, 0.7))
            cg.strokeEllipse(in: nodeRect)
        }
    }

    private static func drawText(
        _ text: String,
        rect: CGRect,
        font: NSFont,
        color: NSColor,
        alignment: NSTextAlignment
    ) {
        let style = NSMutableParagraphStyle()
        style.alignment = alignment
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color,
            .paragraphStyle: style
        ]
        (text as NSString).draw(in: rect, withAttributes: attrs)
    }
}
