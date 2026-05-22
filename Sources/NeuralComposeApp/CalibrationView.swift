import SwiftUI
import BCICore

struct CalibrationView: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header row with active label and recording button
            HStack {
                if viewModel.isCalibrating {
                    HStack(spacing: 8) {
                        Circle()
                            .fill(Color.orange)
                            .frame(width: 12, height: 12)
                        Text("Recording")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                } else {
                    Text("Not Recording")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button(action: toggleRecording) {
                    Text(viewModel.isCalibrating ? "Stop Recording" : "Start Recording")
                        .font(.caption)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(viewModel.isCalibrating ? Color.red.opacity(0.2) : Color.green.opacity(0.2))
                        .cornerRadius(4)
                }
            }

            // Channel metrics (RMS and peak per channel)
            if let metrics = viewModel.calibrationMetrics {
                VStack(spacing: 8) {
                    HStack(spacing: 12) {
                        ForEach(0..<metrics.channelCount, id: \.self) { ch in
                            VStack(spacing: 4) {
                                Text(metrics.channelLabels[ch])
                                    .font(.caption2)
                                    .fontWeight(.semibold)
                                VStack(spacing: 2) {
                                    Text(String(format: "%.1f", metrics.rms[ch]))
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                    Text("RMS µV")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                                VStack(spacing: 2) {
                                    Text(String(format: "%.1f", metrics.peak[ch]))
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                    Text("Peak µV")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                    .padding(12)
                    .background(Color(NSColor.controlBackgroundColor))
                    .cornerRadius(6)
                }
            }

            // Stats row
            HStack(spacing: 16) {
                VStack(spacing: 4) {
                    Text("\(viewModel.calibrationWindowCount)")
                        .font(.callout)
                        .fontWeight(.semibold)
                    Text("Windows")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                VStack(spacing: 4) {
                    Text(String(format: "%.0f", viewModel.calibrationSampleRate))
                        .font(.callout)
                        .fontWeight(.semibold)
                    Text("Hz")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                VStack(spacing: 4) {
                    Text("\(viewModel.droppedWindowCount)")
                        .font(.callout)
                        .fontWeight(.semibold)
                    Text("Dropped")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
            .padding(12)
            .background(Color(NSColor.controlColor))
            .cornerRadius(6)

            // Sticky label buttons (rest, jaw clench, artifact, clear)
            VStack(spacing: 8) {
                Text("Sticky Labels")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(.secondary)
                HStack(spacing: 8) {
                    labelButton("[r] Rest", label: .rest)
                    labelButton("[j] Jaw Clench", label: .jawClench)
                    labelButton("[x] Artifact", label: .artifact)
                    Button(action: clearLabel) {
                        Text("[Esc] Clear")
                            .font(.caption)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(Color(NSColor.controlBackgroundColor))
                            .cornerRadius(4)
                    }
                }
            }

            // Event label buttons (blink, double blink, select)
            VStack(spacing: 8) {
                Text("Event Labels")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(.secondary)
                HStack(spacing: 8) {
                    eventButton("[b] Blink 2s", label: .blink)
                    eventButton("[d] Double Blink 3s", label: .doubleBlink)
                    eventButton("[s] Select 2s", label: .select)
                }
            }
        }
        .padding(12)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
        .border(Color(NSColor.separatorColor), width: 0.5)
    }

    private func labelButton(_ title: String, label: CalibrationLabel) -> some View {
        Button(action: { Task { await viewModel.startStickyLabel(label) } }) {
            Text(title)
                .font(.caption)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(Color.blue.opacity(0.2))
                .cornerRadius(4)
        }
    }

    private func eventButton(_ title: String, label: CalibrationLabel) -> some View {
        Button(action: { Task { await viewModel.addTimedEvent(label) } }) {
            Text(title)
                .font(.caption)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(Color.green.opacity(0.2))
                .cornerRadius(4)
        }
    }

    private func toggleRecording() {
        Task {
            if viewModel.isCalibrating {
                await viewModel.stopCalibrationRecording()
            } else {
                await viewModel.startCalibrationRecording()
            }
        }
    }

    private func clearLabel() {
        Task {
            await viewModel.endStickyLabel()
        }
    }
}
