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
/// The first component hosted here is `EEGScalpPlotterView`. The other
/// 7 components (PSD heatmap, alpha/theta tracker, blink detector, etc.)
/// will be added in subsequent commits.
struct SleepValidationView: View {
    @State private var scaleMicrovoltsPerPixel: Double = 0.5
    @State private var layerDepthSpacing: Double = 30.0
    @State private var timeWindowSeconds: Double = 5.0
    @State private var samplesIngested: UInt64 = 0
    @State private var streamStatus: String = "Idle — open Muse stream to begin"
    @State private var bridgeAvailable: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()
            plotterContainer
            Divider()
            controlsPanel
            Divider()
            statusBar
        }
        .frame(minWidth: 900, minHeight: 600)
        .onAppear {
            bridgeAvailable = bci_bridge_is_available()
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
            if bridgeAvailable {
                Label("BrainFlow linked", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.caption)
            } else {
                Label("BrainFlow not linked — synthetic mode only",
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.caption)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var plotterContainer: some View {
        EEGScalpPlotterRepresentable(
            scaleMicrovoltsPerPixel: $scaleMicrovoltsPerPixel,
            layerDepthSpacing: $layerDepthSpacing,
            timeWindowSeconds: $timeWindowSeconds
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
/// This is the SwiftUI bridge: the plotter is AppKit + Core Animation (for
/// the 3D effect and the 60 Hz display link), but the host is SwiftUI so
/// the user gets a normal macOS view. The wrapper is bidirectional in
/// scale: changes to the SwiftUI bindings update the plotter, and the
/// plotter's actual sample consumption is internal.
struct EEGScalpPlotterRepresentable: NSViewRepresentable {
    @Binding var scaleMicrovoltsPerPixel: Double
    @Binding var layerDepthSpacing: Double
    @Binding var timeWindowSeconds: Double

    func makeNSView(context: Context) -> EEGScalpPlotterView {
        let v = EEGScalpPlotterView(frame: .zero)
        v.scaleMicrovoltsPerPixel = scaleMicrovoltsPerPixel
        v.layerDepthSpacing = layerDepthSpacing
        v.timeWindowSeconds = timeWindowSeconds
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
    }
}
