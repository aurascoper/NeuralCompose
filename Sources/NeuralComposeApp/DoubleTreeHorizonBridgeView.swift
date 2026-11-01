import SwiftUI
import WorldModelDemo

/// Read-only topology viewer for the abstract double-tree graph fixture.
/// Separate from the EEG and live text-generation pipeline.
struct DoubleTreeHorizonBridgeView: View {
    @State private var depth = 3
    @State private var frameIndex = 0
    @State private var fixture: HorizonBridgeFixture?
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Glued Double-Tree Horizon Bridge").font(.title2.bold())
                Spacer()
                Text("Abstract graph topology").font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Text("Horizon depth: \(depth)")
                Slider(value: Binding(get: { Double(depth) }, set: { depth = Int($0.rounded()); rebuild() }), in: 1...6, step: 1)
                    .frame(maxWidth: 220)
                Button("Reset") { frameIndex = 0; rebuild() }
            }
            HStack(spacing: 8) {
                Button("Previous") { frameIndex = max(0, frameIndex - 1) }
                    .disabled(frameIndex == 0)
                Button("Next") { frameIndex = min((fixture?.frames.count ?? 1) - 1, frameIndex + 1) }
                    .disabled(frameIndex >= (fixture?.frames.count ?? 1) - 1)
                Text(fixture?.frames[safe: frameIndex]?.title ?? "Generating…")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let frame = fixture?.frames[safe: frameIndex] {
                HStack(alignment: .top, spacing: 18) {
                    graphCanvas(frame)
                        .frame(minWidth: 440, minHeight: 440)
                    VStack(alignment: .leading, spacing: 8) {
                        metric("Vertices", frame.nodes.count)
                        metric("Edges", frame.edges.count)
                        metric("Components (β₀)", frame.beta0)
                        metric("Cycles (β₁)", frame.beta1)
                        metric("Tarjan bridges", frame.bridgeEdgeCount)
                        Divider()
                        Text("β₁ = E − V + β₀").font(.headline)
                        Text("Counts are computed from this frame’s actual graph, not from the illustration.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.frame(width: 190, alignment: .leading)
                }
            }
            if let errorMessage { Text(errorMessage).foregroundStyle(.red).font(.caption) }
            Spacer()
        }
        .padding(18)
        .onAppear(perform: rebuild)
    }

    private func metric(_ title: String, _ value: Int) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text("\(value)").monospacedDigit().bold()
        }.font(.caption)
    }

    private func graphCanvas(_ frame: HorizonBridgeFrame) -> some View {
        Canvas { context, size in
            let minX = frame.nodes.map(\.x).min() ?? -1
            let maxX = frame.nodes.map(\.x).max() ?? 1
            let minY = frame.nodes.map(\.y).min() ?? -1
            let maxY = frame.nodes.map(\.y).max() ?? 1
            let margin: CGFloat = 28
            let sx = (size.width - 2 * margin) / CGFloat(max(maxX - minX, 1))
            let sy = (size.height - 2 * margin) / CGFloat(max(maxY - minY, 1))
            func point(_ node: HorizonBridgeNode) -> CGPoint {
                CGPoint(x: margin + CGFloat(node.x - minX) * sx,
                        y: margin + CGFloat(maxY - node.y) * sy)
            }
            let lookup = Dictionary(uniqueKeysWithValues: frame.nodes.map { ($0.id, $0) })
            // A subdued horizon band makes the seam visible without adding edges.
            let centerY = margin + CGFloat(maxY) * sy
            context.fill(Path(CGRect(x: 0, y: centerY - 12, width: size.width, height: 24)),
                         with: .color(.yellow.opacity(0.12)))
            for edge in frame.edges {
                guard let a = lookup[edge.a], let b = lookup[edge.b] else { continue }
                var path = Path()
                path.move(to: point(a))
                path.addLine(to: point(b))
                let color: Color = edge.kind == .horizon ? .yellow : (edge.kind == .upperTree ? .cyan : .purple)
                context.stroke(path, with: .color(color.opacity(0.88)),
                               style: StrokeStyle(lineWidth: edge.kind == .horizon ? 3 : 1.4))
            }
            for node in frame.nodes {
                let p = point(node)
                let r: CGFloat = node.region == .horizon ? 5 : 3
                let color: Color = node.region == .horizon ? .yellow : (node.region == .upper ? .cyan : .purple)
                context.fill(Path(ellipseIn: CGRect(x: p.x-r, y: p.y-r, width: 2*r, height: 2*r)),
                             with: .color(color))
            }
        }
        .background(Color.secondary.opacity(0.06))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.2)))
    }

    private func rebuild() {
        do {
            fixture = try DoubleTreeHorizonBridge.make(depth: depth)
            frameIndex = min(frameIndex, (fixture?.frames.count ?? 1) - 1)
            errorMessage = nil
        } catch {
            errorMessage = String(describing: error)
        }
    }
}

private extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
