import SwiftUI
import BCICore
import BCIEEG

/// Track B wizard. Stateless: reads only @Published values from
/// `AppViewModel`; never owns the protocol actor or the recorder directly
/// (those live on the view model so the EEG sample fan-out stays under one
/// supervisor).
struct ImaginedSpeechCalibrationView: View {
    @ObservedObject var viewModel: AppViewModel

    private let config = ImaginedSpeechProtocol.Config()

    var body: some View {
        VStack(spacing: 16) {
            header
            Divider()
            if viewModel.isImaginedSpeechRecording {
                runningPanel
            } else {
                idlePanel
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: "waveform.path.ecg")
                Text("Imagined Speech — Research").font(.headline)
                Spacer()
                if viewModel.isImaginedSpeechRecording {
                    Text("Trial \(viewModel.imaginedSpeechState.trialIndex) / \(viewModel.imaginedSpeechState.totalTrials)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            Text("Track B is experimental — see CLAUDE.md / project memory for the 65% pre-registration gate.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Idle (pre-session)

    private var idlePanel: some View {
        VStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Label("Configuration", systemImage: "list.bullet")
                    .font(.subheadline)
                Text("Cue \(format(config.cueSeconds))s → Imagine \(format(config.activeSeconds))s → Rest \(format(config.restSeconds))s")
                    .font(.callout.monospacedDigit())
                Text("Targets: \(config.activeClasses.map { $0.cueText }.joined(separator: ", "))")
                    .font(.callout)
                Text("\(config.trialsPerClass) trials per class × \(config.activeClasses.count) classes = \(config.totalTrials) trials")
                    .font(.callout.monospacedDigit())
                Text("Estimated duration: \(formatDuration(config.expectedDurationSeconds))")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))

            Text("Sit still, eyes open, focus on a neutral point. During Imagine, silently rehearse the cued word repeatedly until the next phase.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack {
                Spacer()
                Button {
                    Task { await viewModel.startImaginedSpeechSession() }
                } label: {
                    Label("Begin Session", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!viewModel.isRunning)
            }
        }
    }

    // MARK: - Running

    private var runningPanel: some View {
        let state = viewModel.imaginedSpeechState
        return VStack(spacing: 16) {
            HStack {
                Text(state.phase.label)
                    .font(.system(.title3, design: .rounded).weight(.semibold))
                    .foregroundStyle(state.phase.color)
                Spacer()
                Text(String(format: "%.1fs", state.timeRemaining))
                    .font(.system(.title3, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            // Target word — only render during cue/active so rest is a true
            // visual quiet. Reserves the slot to prevent layout jump.
            ZStack {
                Color.clear.frame(height: 120)
                if let target = state.target, state.phase == .cue || state.phase == .active {
                    Text(target.cueText)
                        .font(.system(size: 64, weight: .bold, design: .rounded))
                        .foregroundStyle(state.phase.color)
                        .transition(.opacity)
                } else if state.phase == .rest {
                    Text("rest")
                        .font(.system(size: 28, weight: .regular, design: .rounded))
                        .foregroundStyle(.secondary)
                } else if state.phase == .finished {
                    VStack(spacing: 4) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.largeTitle)
                            .foregroundStyle(.green)
                        Text("Session complete").font(.headline)
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(state.phase.color.opacity(state.phase == .rest ? 0.06 : 0.14))
            )

            // Per-phase progress.
            ProgressView(
                value: max(0.001, state.phaseDuration - state.timeRemaining),
                total: max(0.001, state.phaseDuration)
            )
            .tint(state.phase.color)

            // Session-level progress + stats.
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(
                    value: Double(max(0, state.trialIndex - 1)),
                    total: Double(max(1, state.totalTrials))
                )
                HStack(spacing: 16) {
                    Text("Active samples: \(viewModel.imaginedActiveSampleCount)")
                    Text("Dropped: \(viewModel.imaginedDroppedSampleCount)")
                    Spacer()
                    if let url = viewModel.imaginedSessionURL {
                        Text(url.lastPathComponent)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button(role: .destructive) {
                    Task { await viewModel.stopImaginedSpeechSession() }
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .buttonStyle(.bordered)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: state.phase)
    }

    // MARK: - Formatters

    private func format(_ s: TimeInterval) -> String {
        String(format: "%.1f", s)
    }

    private func formatDuration(_ s: TimeInterval) -> String {
        let total = Int(s.rounded())
        let m = total / 60
        let sec = total % 60
        return String(format: "%d:%02d", m, sec)
    }
}

private extension ImaginedSpeechPhase {
    var label: String {
        switch self {
        case .idle:     return "Idle"
        case .cue:      return "CUE — prepare"
        case .active:   return "IMAGINE"
        case .rest:     return "REST"
        case .finished: return "Finished"
        }
    }
    var color: Color {
        switch self {
        case .idle:     return .secondary
        case .cue:      return .blue
        case .active:   return .green
        case .rest:     return .gray
        case .finished: return .accentColor
        }
    }
}
