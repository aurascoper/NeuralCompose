import SwiftUI
import BCICore

struct ContentView: View {
    @ObservedObject var viewModel: AppViewModel
    @State private var showMetrics: Bool = false
    @State private var showCalibration: Bool = false
    @State private var keyboardMonitor: Any?

    var body: some View {
        VStack(spacing: 0) {
            PrivacyIndicatorView(
                mode: viewModel.pipelineMode,
                lastError: viewModel.lastError,
                signalQuality: viewModel.signalQuality,
                isReconnecting: viewModel.isReconnecting
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

            if showCalibration {
                Divider()
                CalibrationView(viewModel: viewModel)
                    .padding(12)
                    .transition(.opacity)
            }

            Divider()
            ControlsView(viewModel: viewModel, showMetrics: $showMetrics, showCalibration: $showCalibration)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
        }
        .onAppear { setupKeyboardMonitoring() }
        .onDisappear { teardownKeyboardMonitoring() }
        .onChange(of: showCalibration) { _, isOn in
            // Calibration panel just toggled — install or tear down the
            // keyboard monitor accordingly. The original onAppear runs once,
            // before the user has had a chance to enable calibration, so the
            // guard inside setupKeyboardMonitoring fell through and no
            // listener was ever installed. Result: keyboard `r`/`j`/`x`
            // were silently ignored and the only label events came from
            // button clicks (which have no end action → zero-duration
            // sticky events).
            teardownKeyboardMonitoring()
            if isOn { setupKeyboardMonitoring() }
        }
    }

    private func setupKeyboardMonitoring() {
        guard showCalibration else { return }
        let monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { event in
            guard viewModel.isCalibrating else { return event }
            let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
            let isKeyDown = event.type == .keyDown

            if isKeyDown {
                switch key {
                case "r": Task { await viewModel.startStickyLabel(.rest) }
                case "j": Task { await viewModel.startStickyLabel(.jawClench) }
                case "x": Task { await viewModel.startStickyLabel(.artifact) }
                case "b": Task { await viewModel.addTimedEvent(.blink) }
                case "d": Task { await viewModel.addTimedEvent(.doubleBlink) }
                case "s": Task { await viewModel.addTimedEvent(.select) }
                default: break
                }
            } else {
                if ["r", "j", "x"].contains(key) {
                    Task { await viewModel.endStickyLabel() }
                }
            }

            if event.keyCode == 53 { // Escape key
                Task { await viewModel.endStickyLabel() }
            }

            return event
        }
        keyboardMonitor = monitor
    }

    private func teardownKeyboardMonitoring() {
        if let monitor = keyboardMonitor {
            NSEvent.removeMonitor(monitor)
            keyboardMonitor = nil
        }
    }
}

private struct ControlsView: View {
    @ObservedObject var viewModel: AppViewModel
    @Binding var showMetrics: Bool
    @Binding var showCalibration: Bool

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

            Toggle(isOn: $showCalibration) {
                Label("Calibrate", systemImage: "waveform.circle")
            }
            .toggleStyle(.button)
        }
    }
}
