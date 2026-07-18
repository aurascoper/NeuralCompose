import SwiftUI
import WorldModelDemo

/// Standalone research-demo window for the synthetic-task JEPA+MPC spike
/// (see `WorldModel/README.md`, `Sources/WorldModelDemo/`). Never embedded
/// in `ContentView`'s body — reachable only via its own `Window` scene —
/// so it structurally cannot sit on the real typing/generation path.
///
/// Stateless wrapper, mirroring `SleepValidationView`'s "reads only
/// `@Published` values, tolerates a nil view model during the brief
/// loading window" shape.
struct WorldModelMPCDemoView: View {
    let viewModel: AppViewModel?

    var body: some View {
        if let viewModel {
            WorldModelMPCDemoContentView(viewModel: viewModel)
        } else {
            ProgressView("Initializing…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct WorldModelMPCDemoContentView: View {
    @ObservedObject var viewModel: AppViewModel
    @StateObject private var demo: WorldModelMPCDemoViewModel

    init(viewModel: AppViewModel) {
        self.viewModel = viewModel
        _demo = StateObject(wrappedValue: WorldModelMPCDemoViewModel(container: viewModel.container))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if viewModel.worldModelDemoEnabled {
                    HStack(alignment: .top, spacing: 16) {
                        trajectoryPanel
                        diagnosticsPanel
                    }
                    latencyPanel
                    illustrativePanel
                } else {
                    disabledPlaceholder
                }
            }
            .padding(20)
        }
        .onAppear {
            if viewModel.worldModelDemoEnabled { demo.start() }
        }
        .onDisappear { demo.stop() }
        .onChange(of: viewModel.worldModelDemoEnabled) { _, enabled in
            if enabled { demo.start() } else { demo.stop() }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("World Model Demo").font(.title2.bold())
                Spacer()
                Label(
                    demo.engineKind == .coreML ? "CoreML / ANE" : "Baseline controller",
                    systemImage: demo.engineKind == .coreML ? "cpu" : "function"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Text(WorldModelDemoHonesty.headerCaveat)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var disabledPlaceholder: some View {
        VStack(spacing: 8) {
            Image(systemName: "cube.transparent").font(.system(size: 40)).foregroundStyle(.secondary)
            Text("Enable \"Run synthetic-task MPC demo\" in the privacy panel to start.")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 200)
    }

    // MARK: - Panel 1: spatial trajectory

    private var trajectoryPanel: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(demo.scenarioName.isEmpty ? "Trajectory" : "Trajectory — \(demo.scenarioName)")
                .font(.caption.bold())
            Canvas { context, size in
                let arenaHalf: Float = 1.0
                let scale = Float(min(size.width, size.height)) / (arenaHalf * 2.2)
                func point(_ p: WorldModelDemoPoint) -> CGPoint {
                    CGPoint(
                        x: CGFloat((p.x + arenaHalf) * scale) + (size.width - CGFloat(arenaHalf * 2 * scale)) / 2,
                        y: CGFloat((arenaHalf - p.y) * scale) + (size.height - CGFloat(arenaHalf * 2 * scale)) / 2
                    )
                }
                let arenaRect = CGRect(
                    x: point(WorldModelDemoPoint(x: -arenaHalf, y: arenaHalf)).x,
                    y: point(WorldModelDemoPoint(x: -arenaHalf, y: arenaHalf)).y,
                    width: CGFloat(arenaHalf * 2 * scale),
                    height: CGFloat(arenaHalf * 2 * scale)
                )
                context.stroke(Path(arenaRect), with: .color(.secondary.opacity(0.4)), style: StrokeStyle(dash: [3, 3]))

                if let goal = demo.goal {
                    let goalPoint = point(goal)
                    let toleranceRadius = CGFloat(0.1 * Double(scale))
                    context.stroke(
                        Path(ellipseIn: CGRect(x: goalPoint.x - toleranceRadius, y: goalPoint.y - toleranceRadius, width: toleranceRadius * 2, height: toleranceRadius * 2)),
                        with: .color(.black.opacity(0.6)), style: StrokeStyle(dash: [2, 2])
                    )
                    context.fill(Path(ellipseIn: CGRect(x: goalPoint.x - 4, y: goalPoint.y - 4, width: 8, height: 8)), with: .color(.black))
                }

                if demo.trajectory.count > 1 {
                    var path = Path()
                    path.move(to: point(demo.trajectory[0]))
                    for p in demo.trajectory.dropFirst() { path.addLine(to: point(p)) }
                    context.stroke(path, with: .color(.blue), lineWidth: 1.5)
                }
                if let last = demo.trajectory.last {
                    let p = point(last)
                    context.fill(Path(ellipseIn: CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)), with: .color(.red))
                }
            }
            .frame(width: 260, height: 260)
            .background(Color.secondary.opacity(0.05))
        }
    }

    // MARK: - Panel 2: MPPI diagnostics

    private var diagnosticsPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("MPPI diagnostics").font(.caption.bold())
            if let d = demo.diagnostics {
                Text("Effective sample size: \(Int(d.effectiveSampleSize)) / \(512)")
                Text("Cost mean: \(d.costMean, specifier: "%.2f")")
                Text("Stall detected: \(d.stallDetected ? "yes" : "no")")
                    .foregroundStyle(d.stallDetected ? .orange : .secondary)
            } else {
                Text("No planning steps yet").foregroundStyle(.secondary)
            }
            sparkline(demo.essHistory, label: "ESS over time", color: .purple)
            sparkline(demo.costMeanHistory, label: "cost mean over time", color: .orange)
        }
        .font(.caption)
        .frame(width: 260, alignment: .leading)
    }

    // MARK: - Panel 3: planning latency

    private var latencyPanel: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Planning latency").font(.caption.bold())
            if demo.engineKind == .baseline {
                Text("n/a (baseline controller, no CoreML inference)").foregroundStyle(.secondary)
            } else if let last = demo.latencyHistoryMs.last {
                Text("\(last, specifier: "%.1f") ms (last step)")
                sparkline(demo.latencyHistoryMs, label: "latency over time (ms)", color: .teal)
            } else {
                Text("No planning steps yet").foregroundStyle(.secondary)
            }
        }
        .font(.caption)
    }

    // MARK: - Panel 4: illustrative generation panel

    private var illustrativePanel: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Illustrative generation").font(.caption.bold())
            Text(WorldModelDemoHonesty.illustrativeMappingCaveat)
                .font(.caption2)
                .foregroundStyle(.secondary)
            if let warning = demo.illustrativeWarning {
                Text(warning).font(.caption2).foregroundStyle(.orange)
            } else if demo.illustrativeCandidates.isEmpty {
                Text("No candidates yet").font(.caption2).foregroundStyle(.secondary)
            } else {
                HStack(spacing: 8) {
                    ForEach(demo.illustrativeCandidates) { word in
                        Text(word.displayText)
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Color.secondary.opacity(0.12))
                            .cornerRadius(6)
                    }
                }
            }
        }
    }

    private func sparkline(_ values: [Double], label: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Canvas { context, size in
                guard values.count > 1, let maxValue = values.max(), let minValue = values.min(), maxValue > minValue else { return }
                var path = Path()
                for (i, v) in values.enumerated() {
                    let x = CGFloat(i) / CGFloat(values.count - 1) * size.width
                    let normalized = (v - minValue) / (maxValue - minValue)
                    let y = size.height - CGFloat(normalized) * size.height
                    if i == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
                }
                context.stroke(path, with: .color(color), lineWidth: 1.5)
            }
            .frame(height: 40)
        }
    }
}
