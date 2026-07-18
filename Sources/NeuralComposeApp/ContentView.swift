import SwiftUI
import BCICore

/// Top-level UI mode. `.production` is the existing Track A typing pipeline
/// (carousel + gesture calibration). `.research` swaps the Track A calibration
/// panel for the Track B imagined-speech wizard. The EEG stream + classifier
/// run in both modes — Research mode is purely a UI affordance for collecting
/// imagined-speech data; it does not change what Track A does internally.
enum PipelineUIMode: String, CaseIterable, Identifiable {
    case production
    case research
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .production: return "Production"
        case .research:   return "Research (Track B)"
        }
    }
}

struct ContentView: View {
    @ObservedObject var viewModel: AppViewModel
    /// The single command dispatcher shared by every control surface
    /// in this view (Reset / Speak / Refine / Hold-to-Talk buttons,
    /// and the `pendingWindowOpen` / `pendingTab` SwiftUI bridges
    /// below). The same instance is also consumed by the menu items
    /// in `NeuralComposeAppEntry`, so all control surfaces resolve
    /// through one `AppCommand` path.
    let dispatcher: AppCommandDispatcher
    @Environment(\.openWindow) private var openWindow
    @State private var showMetrics: Bool = false
    @State private var showCalibration: Bool = false
    @State private var uiMode: PipelineUIMode = .production
    @State private var keyboardMonitor: Any?
    @State private var showCommandPalette: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            PrivacyIndicatorView(
                mode: viewModel.pipelineMode,
                lastError: viewModel.lastError,
                startupWarning: viewModel.startupWarning,
                signalQuality: viewModel.signalQuality,
                isReconnecting: viewModel.isReconnecting,
                isDictating: viewModel.isDictating,
                isSpeaking: viewModel.isSpeaking,
                isCommanding: viewModel.isCommanding,
                detectedAdaptation: viewModel.detectedAdaptation,
                appliedAdaptation: viewModel.appliedAdaptation,
                detectedSpectralState: viewModel.detectedSpectralState,
                adaptiveComplexityEnabled: $viewModel.adaptiveComplexityEnabled,
                interactionLoggingEnabled: $viewModel.interactionLoggingEnabled,
                jepaTransitionCaptureEnabled: $viewModel.jepaTransitionCaptureEnabled,
                worldModelDemoEnabled: $viewModel.worldModelDemoEnabled
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

            if uiMode == .production, showCalibration {
                Divider()
                CalibrationView(viewModel: viewModel)
                    .padding(12)
                    .transition(.opacity)
            }

            if uiMode == .research {
                Divider()
                ImaginedSpeechCalibrationView(viewModel: viewModel)
                    .transition(.opacity)
            }

            if let refinement = viewModel.refinementSuggestion {
                Divider()
                RefinementSuggestionView(
                    refinement: refinement,
                    onAccept: { Task { await viewModel.acceptRefinement() } },
                    onDismiss: { viewModel.dismissRefinement() }
                )
                .padding(12)
                .transition(.opacity)
            }

            Divider()
            ControlsView(
                viewModel: viewModel,
                dispatcher: dispatcher,
                showMetrics: $showMetrics,
                showCalibration: $showCalibration,
                uiMode: $uiMode
            )
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        // ── Command-dispatch bridges ──────────────────────────────────────
        //    The dispatcher is `@MainActor` but not a SwiftUI view, so
        //    it cannot call `openWindow(id:)` or mutate local `@State`
        //    bindings directly. Instead it sets these transient
        //    `@Published` fields on the view model; the `.onChange`
        //    handlers below perform the actual SwiftUI action and
        //    clear the field so subsequent emissions re-fire.
        .onChange(of: viewModel.pendingWindowOpen) { _, newValue in
            if let id = newValue {
                openWindow(id: id)
                viewModel.pendingWindowOpen = nil
            }
        }
        .onChange(of: viewModel.pendingTab) { _, newValue in
            if let tab = newValue {
                switch tab {
                case .production:  uiMode = .production
                case .research:    uiMode = .research
                case .calibration: showCalibration = true
                }
                viewModel.pendingTab = nil
            }
        }
        .onChange(of: uiMode) { _, newMode in
            handleUIModeChange(newMode)
        }
        .onAppear { setupKeyboardMonitoring() }
        .onDisappear { teardownKeyboardMonitoring() }
        // ── Command palette overlay (⌘⇧P) ────────────────────────────────
        //    Bound to a top-level keyboard shortcut below. The overlay
        //    sits on top of the main content; a scrim behind it captures
        //    click-outside-to-dismiss via the same `showCommandPalette`
        //    binding the palette view uses.
        .overlay {
            if showCommandPalette {
                ZStack {
                    Color.black.opacity(0.25)
                        .ignoresSafeArea()
                        .onTapGesture { showCommandPalette = false }
                    DebugCommandPaletteView(
                        descriptors: dispatcher.commandDescriptors,
                        dispatcher: dispatcher,
                        isPresented: $showCommandPalette
                    )
                }
                .transition(.opacity)
            }
        }
        // Hidden button that captures ⌘⇧P regardless of which
        // subview is focused. `.keyboardShortcut` attaches to a
        // specific view in the hierarchy, so a zero-size button
        // placed at the root reliably captures the global shortcut
        // for the app. The button itself is never rendered visibly.
        .overlay(alignment: .topLeading) {
            Button("") { showCommandPalette.toggle() }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .frame(width: 0, height: 0)
                .opacity(0)
                .accessibilityHidden(true)
        }
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

    /// Extracted from the `onChange(of: uiMode)` closure so the
    /// SwiftUI type-checker doesn't time out on the now-larger body
    /// (this method's calls are simple statements; the closure's
    /// nested `if`-`else if` plus `Task` block was the straw that
    /// broke the compiler's back once the palette overlay and
    /// keyboard-shortcut modifiers were added).
    private func handleUIModeChange(_ newMode: PipelineUIMode) {
        // Leaving Research mode mid-session should stop the Track B
        // recorder cleanly — otherwise the recorder keeps writing
        // to disk for a session the user can no longer see or stop.
        if newMode != .research, viewModel.isImaginedSpeechRecording {
            Task { await viewModel.stopImaginedSpeechSession() }
        }
        // Production-mode keyboard monitor only makes sense in
        // Production.
        if newMode == .research {
            teardownKeyboardMonitoring()
        } else if showCalibration {
            setupKeyboardMonitoring()
        }
    }
}

private struct ControlsView: View {
    @ObservedObject var viewModel: AppViewModel
    /// Shared command dispatcher. Every button in this view routes
    /// through `dispatcher.perform(.X)` rather than calling the
    /// view model directly, so the unified command path covers the
    /// same surfaces the menu items and (future) voice emitter cover.
    let dispatcher: AppCommandDispatcher
    @Binding var showMetrics: Bool
    @Binding var showCalibration: Bool
    @Binding var uiMode: PipelineUIMode

    var body: some View {
        HStack(spacing: 12) {
            Button {
                Task { await dispatcher.perform(.resetComposition) }
            } label: {
                Label("Reset", systemImage: "arrow.counterclockwise")
            }

            Picker("Mode", selection: $uiMode) {
                ForEach(PipelineUIMode.allCases) { m in
                    Text(m.displayName).tag(m)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 260)

            Picker("Classifier", selection: $viewModel.computeMode) {
                ForEach(ClassifierComputeMode.allCases, id: \.self) { m in
                    Text(m.displayName).tag(m)
                }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: 220)

            Spacer()

            // Push-to-talk: mic is open only while this button is held —
            // `pressing:` fires on both press-down and release, which is
            // exactly the push-to-talk lifecycle `.startDictation` /
            // `.stopDictation` expect. Never a toggle/latch. Both
            // press and release route through the dispatcher.
            Button {
                // no-op: press/release handled by `pressing:` below.
            } label: {
                Label(viewModel.isDictating ? "Listening…" : "Hold to Talk", systemImage: "mic.fill")
            }
            .onLongPressGesture(minimumDuration: 0, pressing: { isPressing in
                if isPressing {
                    Task { await dispatcher.perform(.startDictation) }
                } else {
                    Task { await dispatcher.perform(.stopDictation) }
                }
            }, perform: {})

            // Push-to-command: same push-to-talk lifecycle as
            // "Hold to Talk" but a *separate* `SFSpeechRecognizer`
            // instance dedicated to commands. The user can hold
            // both buttons at different times (the buttons share
            // the same TCC permission but distinct recognizers).
            Button {
                // no-op: press/release handled by `pressing:` below.
            } label: {
                Label(viewModel.isCommanding ? "Cmd…" : "Hold to Command", systemImage: "command")
            }
            .onLongPressGesture(minimumDuration: 0, pressing: { isPressing in
                if isPressing {
                    Task { await dispatcher.perform(.startCommand) }
                } else {
                    Task { await dispatcher.perform(.stopCommand) }
                }
            }, perform: {})

            Button {
                Task { await dispatcher.perform(.speak) }
            } label: {
                Label("Speak", systemImage: "speaker.wave.2.fill")
            }
            .disabled(viewModel.composedText.isEmpty || viewModel.isSpeaking)

            Button {
                Task { await dispatcher.perform(.refine) }
            } label: {
                if viewModel.isRefining {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Refine", systemImage: "sparkles")
                }
            }
            .disabled(viewModel.composedText.isEmpty || viewModel.isRefining)

            Toggle(isOn: $showMetrics) {
                Label("Metrics", systemImage: "gauge.with.dots.needle.33percent")
            }
            .toggleStyle(.button)

            if uiMode == .production {
                Toggle(isOn: $showCalibration) {
                    Label("Calibrate", systemImage: "waveform.circle")
                }
                .toggleStyle(.button)
            }
        }
    }
}
