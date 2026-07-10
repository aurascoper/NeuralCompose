import SwiftUI
import AppKit
import BCICore
import BCIBridge
import BCIEEG

/// SwiftUI host for the live 3D neural workspace.
///
/// Hosts a `NeuralWorkspaceView` and a state selector. The view subscribes
/// to the active EEG stream and animates the 4 Muse electrodes in real time
/// with band-power and FSM state.
///
/// This is a Phase B Sleep Validation Toolkit component (#2 in §21 of
/// `SLEEP_CYCLE_DESIGN.md`). It is opened in the same Phase B Debug window
/// as the existing 2D `EEGScalpPlotterView`, in a separate tab.
struct NeuralWorkspaceHost: View {
    /// The running pipeline, or `nil` during the brief loading window
    /// before it is up — same nil-tolerant contract as `SleepValidationView`.
    let viewModel: AppViewModel?

    @State private var fsmState: NeuralWorkspaceView.FSMState = .idle
    @State private var samplesIngested: UInt64 = 0
    @State private var streamStatus: String = "Idle"
    @State private var cameraDistance: Float = 0.30

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()
            NeuralWorkspaceRepresentable(
                cameraDistance: $cameraDistance,
                makeStream: { viewModel?.liveSampleStream() }
            )
                .background(Color(white: 0.05))
            Divider()
            controlsPanel
            Divider()
            statusBar
        }
        .frame(minWidth: 700, minHeight: 600)
    }

    private var headerBar: some View {
        HStack {
            Image(systemName: "cube.transparent")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("3D Neural Workspace — Live EEG Topography")
                .font(.headline)
            Spacer()
            Label("SceneKit", systemImage: "cube.fill")
                .foregroundStyle(.purple)
                .font(.caption)
            Label("vDSP-free", systemImage: "function")
                .foregroundStyle(.secondary)
                .font(.caption)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var controlsPanel: some View {
        HStack(spacing: 16) {
            Picker("FSM state", selection: $fsmState) {
                ForEach([NeuralWorkspaceView.FSMState.idle,
                         .wake, .n1, .n2n3, .rem], id: \.self) { state in
                    Text(state.rawValue).tag(state)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 180)
            .onChange(of: fsmState) { _, newValue in
                NeuralWorkspaceBridge.shared.setFSMState(newValue)
            }

            Divider().frame(height: 22)

            HStack(spacing: 6) {
                Text("Camera distance")
                    .frame(width: 110, alignment: .leading)
                Slider(value: $cameraDistance, in: 0.10...0.80)
                Text(String(format: "%.2f m", cameraDistance))
                    .frame(width: 60, alignment: .trailing)
                    .monospacedDigit()
                    .font(.caption)
            }

            Spacer()
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

/// NSViewRepresentable bridge. The view itself is a SceneKit `SCNView`
/// hosted inside an AppKit `NSView` for full control over the camera
/// and lighting. The SwiftUI side just sets a couple of properties
/// through the bindings.
struct NeuralWorkspaceRepresentable: NSViewRepresentable {
    @Binding var cameraDistance: Float
    let makeStream: () -> AsyncStream<EEGSample>?

    /// Tracks whether the workspace has already been subscribed, matching
    /// `EEGScalpPlotterRepresentable`'s pattern in `SleepValidationView`:
    /// the debug window is normally created before the pipeline is ready,
    /// so subscribing only in `makeNSView` would leave the scene
    /// permanently idle even after samples start flowing.
    final class Coordinator {
        var didSubscribe = false
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NeuralWorkspaceView {
        let v = NeuralWorkspaceView(frame: .zero)
        v.cameraDistance = cameraDistance
        subscribeIfNeeded(v, context.coordinator)
        return v
    }

    func updateNSView(_ nsView: NeuralWorkspaceView, context: Context) {
        if abs(nsView.cameraDistance - cameraDistance) > 0.001 {
            nsView.cameraDistance = cameraDistance
        }
        subscribeIfNeeded(nsView, context.coordinator)
    }

    private func subscribeIfNeeded(_ v: NeuralWorkspaceView, _ coordinator: Coordinator) {
        guard !coordinator.didSubscribe, let stream = makeStream() else { return }
        coordinator.didSubscribe = true
        v.subscribe(to: Self.throwingStream(from: stream))
    }

    /// Wrap an `AsyncStream<EEGSample>` in an
    /// `AsyncThrowingStream<EEGSample, any Error>` — see the identical
    /// helper on `EEGScalpPlotterRepresentable` in `SleepValidationView.swift`
    /// for why the throwing wrapper is needed even though this never throws.
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

/// A small singleton so the SwiftUI host can push FSM state into the
/// workspace without holding a direct reference (which would conflict
/// with the NSViewRepresentable lifecycle).
@MainActor
final class NeuralWorkspaceBridge {
    static let shared = NeuralWorkspaceBridge()
    weak var view: NeuralWorkspaceView?
    func setFSMState(_ state: NeuralWorkspaceView.FSMState) {
        view?.setFSMState(state)
    }
}
