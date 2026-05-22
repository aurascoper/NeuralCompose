import SwiftUI
import BCICore

/// Compact pipeline summary shown in the menu-bar extra. Lets the user peek
/// at the current carousel state and the privacy mode without surfacing the
/// full window.
struct MenuBarView: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "brain.head.profile")
                Text("NeuralCompose").bold()
                Spacer()
            }
            Divider()
            Text(viewModel.composedText.isEmpty ? "—" : viewModel.composedText)
                .font(.body)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 6) {
                ForEach(Array(viewModel.candidates.enumerated()), id: \.element.id) { (idx, w) in
                    Text(w.displayText)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            Capsule().fill(
                                idx == viewModel.highlightIndex
                                    ? Color.accentColor.opacity(0.25)
                                    : Color.secondary.opacity(0.08)
                            )
                        )
                }
                if viewModel.candidates.isEmpty {
                    Text("…").foregroundStyle(.secondary)
                }
            }

            Divider()
            HStack {
                Text(viewModel.pipelineMode.substitutionSummary)
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Reset") {
                    Task { await viewModel.resetComposition() }
                }
            }
        }
        .padding(12)
        .frame(width: 320)
    }
}
