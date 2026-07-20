import SwiftUI
import AppKit
import BCICore
import BCIBridge
import BCIEEG

/// SwiftUI host for the Phase B Sleep Validation Toolkit.
///
/// This is the debug view referenced by §21.3 of the design doc. It is NOT
/// the user-facing sleep mode; it is a developer tool for validating the
/// raw Muse EEG signal. The view opens in a separate window (via the
/// "Open Phase B Debug" menu item or programmatically).
///
/// Components hosted here:
///  * `EEGScalpPlotterView` — the depth-stacked 2D plotter.
///  * `NeuralWorkspaceHost` — the SceneKit 3D neural workspace.
///  * A per-channel health badge that reads from a
///    `ChannelHealthProviding` constructed from the same live sample
///    stream that feeds the plotter.
///
/// The view does NOT own the EEG stream. The view receives an
/// `AppViewModel?` (nil during the brief loading window before the
/// pipeline is up) and reads `viewModel.liveSampleStream()` for both
/// the plotter subscription and the channel-health provider. See
/// `AppViewModel.liveSampleStream()` for the single-owner invariant
/// on the live EEG stream.
struct SleepValidationView: View {
    /// The running pipeline, or `nil` during the brief loading window
    /// before it is up. This is a plain `let`, not `@ObservedObject`:
    /// `@ObservedObject` requires an `ObservableObject`, and `Optional`
    /// does not conform. Reactivity is handled by the parent scene —
    /// `NeuralComposeAppEntry` observes the `AppLoader` and re-creates
    /// this view with the bound view model once the pipeline is ready.
    let viewModel: AppViewModel?

    @State private var scaleMicrovoltsPerPixel: Double = 0.5
    @State private var layerDepthSpacing: Double = 30.0
    @State private var timeWindowSeconds: Double = 5.0
    @State private var samplesIngested: UInt64 = 0
    @State private var streamStatus: String = "Idle — open Muse stream to begin"
    @State private var bridgeAvailable: Bool = false
    @State private var selectedTab: Int = 0
    @State private var channelHealth: [ChannelHealthState] = initialChannelHealthStates()

    /// Muse S layout. Used to populate the per-channel badge row
    /// before any samples have been received and to construct the
    /// `EEGChannelHealthProvider` when the live stream becomes
    /// available.
    private static let museChannelLabels = ["TP9", "AF7", "AF8", "TP10"]

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            channelHealthBar
            Divider()
            Picker("", selection: $selectedTab) {
                Text("2D Plotter").tag(0)
                Text("3D Workspace").tag(1)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            Divider()
            if selectedTab == 0 {
                plotterContainer
                Divider()
                controlsPanel
                Divider()
                statusBar
            } else {
                NeuralWorkspaceHost(viewModel: viewModel)
            }
        }
        .frame(minWidth: 900, minHeight: 600)
        .onAppear {
            bridgeAvailable = bci_bridge_is_available()
        }
        // The health provider drains the live sample stream and
        // updates `channelHealth` once per second. The task re-runs
        // when the view model's identity changes (initially nil during
        // pipeline load, then the running `AppViewModel`). We key on
        // `ObjectIdentifier` because `AppViewModel` is a reference type
        // and `.task(id:)` requires an `Equatable` id.
        .task(id: viewModel.map { ObjectIdentifier($0) }) {
            await runHealthPolling()
        }
    }

    // MARK: - Wiring

    /// Drain the live sample stream through an
    /// `EEGChannelHealthProvider` and update `channelHealth` once
    /// per second. The provider is constructed from the same
    /// `AsyncStream<EEGSample>` that the plotter subscribes to; if
    /// `viewModel` is nil (pipeline still loading), this returns
    /// immediately and the task will be re-invoked when the view
    /// model binds.
    @MainActor
    private func runHealthPolling() async {
        guard let viewModel = viewModel else { return }
        let stream = viewModel.liveSampleStream()
        let provider = EEGChannelHealthProvider(
            stream: stream,
            channelCount: 4,
            channelLabels: Self.museChannelLabels,
            sampleRate: 256.0,
            ringSeconds: 4.0
        )
        while !Task.isCancelled {
            let states = await provider.currentChannelHealth(windowSeconds: 1.0)
            channelHealth = states
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }

    // MARK: - Sub-views

    private var headerBar: some View {
        HStack {
            Image(systemName: "waveform.path.ecg.rectangle")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("Sleep Validation Toolkit — Phase B")
                .font(.headline)
            Spacer()
            sourceBadge
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// EEG-source badge. Reflects the ACTUAL acquisition, not just whether the
    /// BrainFlow bridge was compiled in. The toolkit streams from the app's live
    /// pipeline (`liveSampleStream()`), so a live OSC / Mind Monitor session is
    /// real EEG even though `bci_bridge_is_available()` is false (BrainFlow is an
    /// optional system lib, not the only live source). The old label read
    /// "BrainFlow not linked — synthetic mode only," which mis-reported exactly
    /// that case — a live remote-phone stream shown as synthetic.
    @ViewBuilder private var sourceBadge: some View {
        switch viewModel?.pipelineMode.acquisition {
        case .some(.synthetic):
            Label("Synthetic EEG — no live source", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.caption)
        case .some(let acquisition):  // .remotePhone (OSC) / .localMuse (BLE) / .playback
            Label("Live EEG — \(acquisition.displayName)", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.caption)
        case .none:
            // Pipeline not bound yet (the debug window can open before it's up).
            Label(bridgeAvailable ? "BrainFlow linked" : "Waiting for live source…",
                  systemImage: bridgeAvailable ? "checkmark.circle.fill" : "hourglass")
                .foregroundStyle(bridgeAvailable ? Color.green : Color.secondary)
                .font(.caption)
        }
    }

    /// Per-channel health badge. Shows TP9, AF7, AF8, TP10 with
    /// their current health state (healthy / saturated / dead /
    /// unknown). Reads from the `EEGChannelHealthProvider` started
    /// by `runHealthPolling()`. When the view first appears and no
    /// samples have arrived yet, every channel shows `.unknown`
    /// (the badge does not synthesize fake health numbers).
    private var channelHealthBar: some View {
        HStack(spacing: 8) {
            ForEach(channelHealth, id: \.channel) { ch in
                ChannelHealthBadge(state: ch)
            }
            Spacer()
            let healthyCount = channelHealth.filter { $0.status == .healthy }.count
            if healthyCount > 0 && healthyCount < 4 {
                Label("\(healthyCount)-of-4 mode",
                      systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .font(.caption.bold())
            } else if healthyCount == 4 {
                Label("All channels healthy",
                      systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                    .font(.caption.bold())
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(white: 0.07))
    }

    private var plotterContainer: some View {
        // The representable subscribes the plotter to the live sample
        // stream the first time one is available. `makeStream` is a
        // closure (not a pre-built stream) so that if `viewModel` is
        // nil when the window first renders — which it usually is, the
        // debug window opens before the pipeline is up — the plotter
        // still picks up the stream on a later update once the view
        // model binds, instead of rendering forever against an empty
        // buffer.
        EEGScalpPlotterRepresentable(
            scaleMicrovoltsPerPixel: $scaleMicrovoltsPerPixel,
            layerDepthSpacing: $layerDepthSpacing,
            timeWindowSeconds: $timeWindowSeconds,
            makeStream: { viewModel?.liveSampleStream() }
        )
        .background(Color.black)
    }

    private var controlsPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Toggle("3D depth stack", isOn: Binding(
                    get: { layerDepthSpacing > 0 },
                    set: { layerDepthSpacing = $0 ? 30.0 : 0.0 }
                ))
                .toggleStyle(.switch)
                .help("When on, channels render at different z-depths for visual separation.")
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Y-scale (µV/pixel)")
                        .frame(width: 160, alignment: .leading)
                    Slider(value: $scaleMicrovoltsPerPixel, in: 0.05...5.0)
                    Text(String(format: "%.2f", scaleMicrovoltsPerPixel))
                        .frame(width: 60, alignment: .trailing)
                        .monospacedDigit()
                }
                Text("Lower = more vertical zoom. 0.5 shows ±50 µV full-scale at 200 pt layer height.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Z-depth spacing (pt)")
                        .frame(width: 160, alignment: .leading)
                    Slider(value: $layerDepthSpacing, in: 0.0...100.0)
                    Text(String(format: "%.0f", layerDepthSpacing))
                        .frame(width: 60, alignment: .trailing)
                        .monospacedDigit()
                }
                Text("Visual separation between channel layers in points. 30 pt = clearly separated, 100 pt = strong 3D, 0 = 2D overlay.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Time window (s)")
                        .frame(width: 160, alignment: .leading)
                    Slider(value: $timeWindowSeconds, in: 1.0...30.0)
                    Text(String(format: "%.1f", timeWindowSeconds))
                        .frame(width: 60, alignment: .trailing)
                        .monospacedDigit()
                }
                Text("How many seconds of recent history are visible on the x-axis.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
    }

    private var statusBar: some View {
        HStack {
            Text(streamStatus)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
            Spacer()
            Text("Samples ingested: \(samplesIngested)")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

/// NSViewRepresentable wrapper around the AppKit-based `EEGScalpPlotterView`.
///
/// The wrapper is bidirectional in scale: changes to the SwiftUI
/// bindings update the plotter, and the plotter's actual sample
/// consumption is internal. `makeStream` is called to obtain the live
/// sample stream; it returns nil while the pipeline is still loading.
/// The plotter subscribes exactly once, the first time `makeStream`
/// yields a non-nil stream — at `makeNSView` if the pipeline is already
/// up, otherwise on the first `updateNSView` after the view model binds.
/// This matters because the debug window is normally created before the
/// pipeline is ready, so subscribing only in `makeNSView` would leave
/// the plotter permanently blank even after samples start flowing.
struct EEGScalpPlotterRepresentable: NSViewRepresentable {
    @Binding var scaleMicrovoltsPerPixel: Double
    @Binding var layerDepthSpacing: Double
    @Binding var timeWindowSeconds: Double
    let makeStream: () -> AsyncStream<EEGSample>?

    /// Tracks whether the plotter has already been subscribed, so we do
    /// it once across the view's lifetime rather than on every update
    /// (each `makeStream()` call would otherwise open a new subscription).
    final class Coordinator {
        var didSubscribe = false
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> EEGScalpPlotterView {
        let v = EEGScalpPlotterView(frame: .zero)
        v.scaleMicrovoltsPerPixel = scaleMicrovoltsPerPixel
        v.layerDepthSpacing = layerDepthSpacing
        v.timeWindowSeconds = timeWindowSeconds
        subscribeIfNeeded(v, context.coordinator)
        return v
    }

    func updateNSView(_ nsView: EEGScalpPlotterView, context: Context) {
        if nsView.scaleMicrovoltsPerPixel != scaleMicrovoltsPerPixel {
            nsView.scaleMicrovoltsPerPixel = scaleMicrovoltsPerPixel
        }
        if nsView.layerDepthSpacing != layerDepthSpacing {
            nsView.layerDepthSpacing = layerDepthSpacing
        }
        if nsView.timeWindowSeconds != timeWindowSeconds {
            nsView.timeWindowSeconds = timeWindowSeconds
        }
        subscribeIfNeeded(nsView, context.coordinator)
    }

    /// Subscribe the plotter to the live stream the first time one is
    /// available. No-op once subscribed, or while `makeStream()` is nil.
    private func subscribeIfNeeded(_ v: EEGScalpPlotterView, _ coordinator: Coordinator) {
        guard !coordinator.didSubscribe, let stream = makeStream() else { return }
        coordinator.didSubscribe = true
        v.subscribe(to: Self.throwingStream(from: stream))
    }

    /// Wrap an `AsyncStream<EEGSample>` in an
    /// `AsyncThrowingStream<EEGSample, any Error>` so the plotter's
    /// generic `subscribe<Failure: Error>(to:)` can be used without
    /// change. The failure type is `any Error` (not `Never`) because
    /// the `AsyncThrowingStream` closure initializer only exists when
    /// `Failure == any Error`; this stream never actually throws — it
    /// only yields and finishes. Cancellation of the wrapper's source
    /// propagates to the inner stream's drain task.
    private static func throwingStream(
        from stream: AsyncStream<EEGSample>
    ) -> AsyncThrowingStream<EEGSample, any Error> {
        AsyncThrowingStream<EEGSample, any Error> { continuation in
            let task = Task {
                for await sample in stream {
                    continuation.yield(sample)
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

// MARK: - Per-channel health badge
//
// Renders a single `ChannelHealthState` (from `BCICore`) as a
// compact pill. The status drives the dot color and the label
// color. RMS is shown as a µV reading when samples are available.

struct ChannelHealthBadge: View {
    let state: ChannelHealthState

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
            Text(state.channel.label)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(statusColor)
                .frame(width: 36, alignment: .leading)
            Text(displayString)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(statusColor)
                .frame(width: 28, alignment: .leading)
            if state.samples > 0 {
                Text(String(format: "%.0fµV", state.rms))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(Color(white: 0.15))
        )
    }

    /// Short abbreviation for the badge slot. The view prefers
    /// these short strings to the enum's rawValue because the badge
    /// is space-constrained.
    private var displayString: String {
        switch state.status {
        case .unknown:   return "?"
        case .healthy:   return "OK"
        case .saturated: return "Sat"
        case .dead:      return "Dead"
        case .stale:     return "Stale"
        }
    }

    private var statusColor: Color {
        switch state.status {
        case .healthy:   return .green
        case .saturated: return .red
        case .dead:      return .gray
        case .unknown:   return .secondary
        // Distinct from every other bucket on purpose — `.dead` and
        // `.unknown` are already gray/secondary, and `.stale` needs to
        // read as "this reading is old," not "this electrode is bad."
        case .stale:     return .yellow
        }
    }
}

// MARK: - Initial state for the badge row
//
// The view needs an initial set of `ChannelHealthState` values so
// the badge row can render before any samples have arrived. Each
// state has `.unknown` status and zero samples. The labels come
// from the project's canonical Muse layout.
private func initialChannelHealthStates() -> [ChannelHealthState] {
    [
        ChannelHealthState(channel: .tp9,  status: .unknown, rms: 0, samples: 0, timestamp: 0),
        ChannelHealthState(channel: .af7,  status: .unknown, rms: 0, samples: 0, timestamp: 0),
        ChannelHealthState(channel: .af8,  status: .unknown, rms: 0, samples: 0, timestamp: 0),
        ChannelHealthState(channel: .tp10, status: .unknown, rms: 0, samples: 0, timestamp: 0),
    ]
}
