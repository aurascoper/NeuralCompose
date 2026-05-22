import SwiftUI
import BCICore

/// Always-visible banner telling the user what's actually running. Green
/// when every stage is real; amber when any stage is a stand-in; red when a
/// hard error has been surfaced.
struct PrivacyIndicatorView: View {
    let mode: PipelineMode
    let lastError: String?

    @State private var expanded: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Circle().fill(statusColor).frame(width: 10, height: 10)
                Text(statusTitle).font(.callout.bold())
                Text(mode.substitutionSummary).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(action: { expanded.toggle() }) {
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                }
                .buttonStyle(.borderless)
            }
            if expanded {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                    GridRow {
                        Text("EEG").bold()
                        Text("\(mode.sourceProfile.displayName) (\(mode.source.rawValue))")
                    }
                    GridRow {
                        Text("Classifier").bold()
                        Text(mode.classifier.rawValue)
                    }
                    GridRow {
                        Text("Predictor").bold()
                        Text(mode.predictor.rawValue)
                    }
                    GridRow {
                        Text("Network").bold()
                        Text("Disabled at runtime").foregroundStyle(.green)
                    }
                }
                .font(.caption)

                if let err = lastError {
                    Divider().padding(.vertical, 2)
                    Label(err, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.caption)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(statusColor.opacity(0.08))
    }

    private var statusTitle: String {
        if lastError != nil           { return "Degraded — see details" }
        if mode.isFullyLive           { return "Live pipeline" }
        return "Standby pipeline"
    }
    private var statusColor: Color {
        if lastError != nil           { return .red }
        if mode.isFullyLive           { return .green }
        return .orange
    }
}
