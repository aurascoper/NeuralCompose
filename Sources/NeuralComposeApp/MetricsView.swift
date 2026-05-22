import SwiftUI
import BCICore

struct MetricsView: View {
    let snapshot: MetricsCollector.Snapshot
    let mode: PipelineMode

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
            GridRow {
                Text("Stage").bold()
                Text("Count").bold()
                Text("Avg µs").bold()
                Text("p95 µs").bold()
            }
            row(label: "Windowing",      stage: snapshot.windowing)
            row(label: "Classification", stage: snapshot.classification,
                trailing: "\(snapshot.classifierMode.displayName)")
            row(label: "Prediction",     stage: snapshot.prediction,
                trailing: snapshot.predictorIdentifier)

            Divider().gridCellColumns(4).padding(.vertical, 2)

            GridRow {
                Text("Carousel ticks").bold()
                Text("\(snapshot.carouselTicks)")
                Text("Commits").bold()
                Text("\(snapshot.selectionCommits)")
            }

            if !snapshot.recentIntents.isEmpty {
                GridRow {
                    Text("Recent intents").bold()
                    Text(snapshot.recentIntents.map(emoji).joined())
                        .gridCellColumns(3)
                }
            }
        }
        .font(.system(.caption, design: .monospaced))
    }

    @ViewBuilder
    private func row(label: String,
                     stage: MetricsCollector.Stage,
                     trailing: String? = nil) -> some View {
        GridRow {
            HStack(spacing: 6) {
                Text(label)
                if let t = trailing { Text("(\(t))").foregroundStyle(.secondary) }
            }
            Text("\(stage.count)")
            Text(String(format: "%.0f", stage.avgMicros))
            Text("\(stage.p95Micros)")
        }
    }

    private func emoji(for intent: SmoothedIntent) -> String {
        switch intent {
        case .idle:         return "·"
        case .advance:      return "›"
        case .selectActive: return "✓"
        }
    }
}
