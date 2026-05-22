import SwiftUI
import BCICore

/// Always-visible banner telling the user what's actually running. Green
/// when every stage is real; amber when any stage is a stand-in; red when a
/// hard error has been surfaced.
struct PrivacyIndicatorView: View {
    let mode: PipelineMode
    let lastError: String?
    var signalQuality: SignalQuality? = nil
    var isReconnecting: Bool = false

    @State private var expanded: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Circle().fill(statusColor).frame(width: 10, height: 10)
                Text(statusTitle).font(.callout.bold())
                Text(mode.substitutionSummary).font(.caption).foregroundStyle(.secondary)
                Spacer()
                signalBadge
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
        if isReconnecting             { return "Reconnecting…" }
        if lastError != nil           { return "Degraded — see details" }
        if mode.isFullyLive           { return "Live pipeline" }
        return "Standby pipeline"
    }
    private var statusColor: Color {
        if isReconnecting             { return .orange }
        if lastError != nil           { return .red }
        if mode.isFullyLive           { return .green }
        return .orange
    }

    @ViewBuilder
    private var signalBadge: some View {
        if let q = signalQuality, mode.source != .synthetic {
            HStack(spacing: 4) {
                Image(systemName: signalIcon(q))
                    .foregroundStyle(signalColor(q))
                Text(signalLabel(q))
                    .font(.caption)
                    .foregroundStyle(signalColor(q))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(signalColor(q).opacity(0.12))
            .cornerRadius(4)
        }
    }

    private func signalIcon(_ q: SignalQuality) -> String {
        switch q {
        case .healthy: return "waveform"
        case .poor:    return "waveform.path.badge.minus"
        case .lost:    return "waveform.slash"
        }
    }
    private func signalColor(_ q: SignalQuality) -> Color {
        switch q {
        case .healthy: return .green
        case .poor:    return .orange
        case .lost:    return .red
        }
    }
    private func signalLabel(_ q: SignalQuality) -> String {
        switch q {
        case .healthy: return "Signal OK"
        case .poor:    return "Signal weak"
        case .lost:    return "No signal"
        }
    }
}
