import SwiftUI
import BCICore

struct ContentView: View {
    @ObservedObject var viewModel: AppViewModel
    @State private var showMetrics: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            PrivacyIndicatorView(
                mode: viewModel.pipelineMode,
                lastError: viewModel.lastError
            )
            Divider()

            // Composed sentence area.
            ScrollView {
                Text(viewModel.composedText.isEmpty ? "—" : viewModel.composedText)
                    .font(.system(size: 28, weight: .medium, design: .serif))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 28)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: .infinity)

            // Carousel.
            PredictionCarouselView(
                candidates: viewModel.candidates,
                highlightIndex: viewModel.highlightIndex,
                isPredicting: viewModel.isPredicting,
                lastCommittedWord: viewModel.lastCommittedWord
            )
            .padding(.horizontal, 16)
            .padding(.vertical, 16)

            if showMetrics {
                Divider()
                MetricsView(snapshot: viewModel.metricsSnapshot, mode: viewModel.pipelineMode)
                    .padding(12)
                    .transition(.opacity)
            }

            Divider()
            ControlsView(viewModel: viewModel, showMetrics: $showMetrics)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
        }
    }
}

private struct ControlsView: View {
    @ObservedObject var viewModel: AppViewModel
    @Binding var showMetrics: Bool

    var body: some View {
        HStack(spacing: 12) {
            Button {
                Task { await viewModel.resetComposition() }
            } label: {
                Label("Reset", systemImage: "arrow.counterclockwise")
            }

            Picker("Classifier", selection: $viewModel.computeMode) {
                ForEach(ClassifierComputeMode.allCases, id: \.self) { m in
                    Text(m.displayName).tag(m)
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 260)

            Spacer()

            Toggle(isOn: $showMetrics) {
                Label("Metrics", systemImage: "gauge.with.dots.needle.33percent")
            }
            .toggleStyle(.button)
        }
    }
}
