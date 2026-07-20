import SwiftUI
import BCICore

/// Always-visible banner telling the user what's actually running. Green
/// when every stage is real; amber when any stage is a stand-in; red when a
/// hard error has been surfaced.
struct PrivacyIndicatorView: View {
    let mode: PipelineMode
    let lastError: String?
    /// One-time startup substitution notice (classifier/predictor fell back
    /// at launch) — informational, not a live pipeline failure. Shown with
    /// a neutral icon, distinct from `lastError`'s alarm styling, and never
    /// factors into `statusColor`/`statusTitle`.
    var startupWarning: String? = nil
    var signalQuality: SignalQuality? = nil
    var isReconnecting: Bool = false
    var isDictating: Bool = false
    var isSpeaking: Bool = false
    var isCommanding: Bool = false
    /// What the current signal quality maps to via the deterministic rule
    /// table — kept current regardless of whether adaptive mode is applied
    /// ("shadow mode"), so the badge is informative even while off.
    var detectedAdaptation: GenerationAdaptation = .raw
    /// What's actually been pushed to generation — equals `.raw` whenever
    /// `adaptiveComplexityEnabled` is false.
    var appliedAdaptation: GenerationAdaptation = .raw
    /// Milestone B state source — always current regardless of the toggle
    /// (shadow mode), same invariant as `detectedAdaptation`. `nil` means
    /// the estimator has no opinion; the combination logic falls back to
    /// `signalQuality` in that case (see `AdaptiveGenerationCombination`).
    var detectedSpectralState: SpectralState? = nil
    @Binding var adaptiveComplexityEnabled: Bool
    /// Opt-in, off by default — see
    /// `docs/architecture/decision-log/ADR-005-local-interaction-logging.md`.
    /// Never transmitted anywhere; written only to a local JSONL file.
    @Binding var interactionLoggingEnabled: Bool
    /// Separate opt-in for the higher-sensitivity paired EEG feature data set.
    /// The app keeps this visible as a distinct recording state rather than
    /// silently broadening the existing interaction log.
    @Binding var jepaTransitionCaptureEnabled: Bool
    /// Separate opt-in for the synthetic-task World Model MPC demo window
    /// (see `Sources/WorldModelDemo/`). Unlike the toggles above, this
    /// gates no data persistence at all — the demo reads nothing real and
    /// writes nothing to disk in either state; it only controls whether
    /// the demo window's closed-loop simulation actually runs.
    @Binding var worldModelDemoEnabled: Bool
    /// Experimental opt-in for the spoken-generation loop. Like
    /// `worldModelDemoEnabled` it persists nothing; red means "the loop is
    /// actively speaking generated text," not "recording."
    @Binding var spokenGenerationLoopEnabled: Bool
    /// Experimental opt-in for the hypnagogic loop. UNIQUE among these toggles:
    /// while active it both captures the mic (on-device STT) AND may send
    /// transcript text to a cloud assistant — the one deliberate runtime network
    /// exception (decision_registry entry 8). Red = "listening + text may leave."
    @Binding var hypnagogicLoopEnabled: Bool
    /// Which hypnagogic engine runs when enabled: the plain mirror reply, or the
    /// dialectic competition (two cloud calls/turn).
    @Binding var hypnagogicMode: HypnagogicMode

    @State private var expanded: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Circle().fill(statusColor).frame(width: 10, height: 10)
                Text(statusTitle).font(.callout.bold())
                Text(mode.substitutionSummary).font(.caption).foregroundStyle(.secondary)
                Spacer()
                signalBadge
                adaptiveBadge
                interactionLogBadge
                jepaCaptureBadge
                worldModelDemoBadge
                spokenLoopBadge
                hypnagogicLoopBadge
                voiceBadge
                cmdBadge
                Button(action: { expanded.toggle() }) {
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                }
                .buttonStyle(.borderless)
            }
            if expanded {
                Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 4) {
                    GridRow {
                        Text("EEG").bold()
                        HStack(spacing: 6) {
                            Text(mode.sourceProfile.displayName)
                            ForEach(mode.acquisitionBadges, id: \.self) { badge in
                                Text(badge)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 1)
                                    .background(Color.secondary.opacity(0.15))
                                    .cornerRadius(3)
                            }
                        }
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
                        if hypnagogicLoopEnabled {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Cloud active — Hypnagogic (\(hypnagogicMode.label))").foregroundStyle(.red)
                                Text(hypnagogicMode == .dialectic
                                     ? "Transcript text (never audio) may be sent to the claude CLI — two calls per turn in Dialectic mode. Opt-in exception — see decision_registry entry 8."
                                     : "Transcript text (never audio) may be sent to the claude CLI. Opt-in exception — see decision_registry entry 8.")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        } else {
                            Text("Disabled at runtime").foregroundStyle(.green)
                        }
                    }
                    GridRow {
                        Text("Adaptive").bold()
                        VStack(alignment: .leading, spacing: 2) {
                            Toggle("Apply to generation", isOn: $adaptiveComplexityEnabled)
                                .toggleStyle(.switch)
                            Text("Detected: \(adaptiveStateLabel(signalQuality: signalQuality, spectralState: detectedSpectralState)) — \(detectedAdaptation.maxCandidates) candidates, temp \(detectedAdaptation.temperature, specifier: "%.2f")")
                                .foregroundStyle(.secondary)
                            if let spectral = detectedSpectralState {
                                Text("Spectral: \(spectral.badgeLabel)")
                                    .foregroundStyle(.secondary)
                                Text(SpectralState.honestyCaveat)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            } else {
                                Text("Spectral: unavailable — using signal-quality fallback")
                                    .foregroundStyle(.secondary)
                            }
                            if adaptiveComplexityEnabled {
                                Text("Applied: \(appliedAdaptation.maxCandidates) candidates, temp \(appliedAdaptation.temperature, specifier: "%.2f")")
                            } else {
                                Text("Not applied — generation is using defaults")
                                    .foregroundStyle(.secondary)
                            }
                            if !detectedAdaptation.styleInstruction.isEmpty {
                                Text("Would prompt: \"\(detectedAdaptation.styleInstruction)\"")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    GridRow {
                        Text("Interaction Log").bold()
                        VStack(alignment: .leading, spacing: 2) {
                            Toggle("Log commits locally", isOn: $interactionLoggingEnabled)
                                .toggleStyle(.switch)
                            if interactionLoggingEnabled {
                                Text("Recording each committed word + detected state to")
                                    .foregroundStyle(.secondary)
                                Text("~/Documents/NeuralCompose/InteractionLogs/")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            } else {
                                Text("Off — nothing is written")
                                    .foregroundStyle(.secondary)
                            }
                            Text("Local only, never transmitted — see ADR-005.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    GridRow {
                        Text("JEPA Dataset").bold()
                        VStack(alignment: .leading, spacing: 2) {
                            Toggle("Capture EEG transitions locally", isOn: $jepaTransitionCaptureEnabled)
                                .toggleStyle(.switch)
                            if jepaTransitionCaptureEnabled {
                                Text("Recording paired EEG windows and generation settings to")
                                    .foregroundStyle(.secondary)
                                Text("~/Documents/NeuralCompose/JEPATransitions/")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            } else {
                                Text("Off - no JEPA transition data is written")
                                    .foregroundStyle(.secondary)
                            }
                            Text("Local only; records no composed text or committed words.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    GridRow {
                        Text("World Model Demo").bold()
                        VStack(alignment: .leading, spacing: 2) {
                            Toggle("Run synthetic-task MPC demo", isOn: $worldModelDemoEnabled)
                                .toggleStyle(.switch)
                            if worldModelDemoEnabled {
                                Text("Demo window runs a self-contained simulation; reads nothing real, writes nothing to disk.")
                                    .foregroundStyle(.secondary)
                            } else {
                                Text("Off — demo window is idle; nothing is read or written")
                                    .foregroundStyle(.secondary)
                            }
                            Text("Synthetic 2D task only — never reads real EEG. See WorldModel/README.md.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    GridRow {
                        Text("Spoken Loop").bold()
                        VStack(alignment: .leading, spacing: 2) {
                            Toggle("Run spoken generation loop", isOn: $spokenGenerationLoopEnabled)
                                .toggleStyle(.switch)
                            if spokenGenerationLoopEnabled {
                                Text(SpokenGenerationHonesty.captureContaminationCaveat)
                                    .foregroundStyle(.red)
                            }
                            Text(SpokenGenerationHonesty.headerCaveat)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    GridRow {
                        Text("Hypnagogic").bold()
                        VStack(alignment: .leading, spacing: 2) {
                            Toggle("Run hypnagogic loop", isOn: $hypnagogicLoopEnabled)
                                .toggleStyle(.switch)
                            Picker("Engine", selection: $hypnagogicMode) {
                                ForEach(HypnagogicMode.allCases) { Text($0.label).tag($0) }
                            }
                            .pickerStyle(.segmented)
                            if hypnagogicLoopEnabled {
                                Text(HypnagogicDialecticHonesty.egressCaveat)
                                    .foregroundStyle(.red)
                                if hypnagogicMode == .dialectic {
                                    Text(HypnagogicDialecticHonesty.dialecticCaveat)
                                        .font(.caption2)
                                        .foregroundStyle(.red)
                                }
                            }
                            Text(HypnagogicDialecticHonesty.headerCaveat)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .font(.caption)

                if let warning = startupWarning {
                    Divider().padding(.vertical, 2)
                    Label(warning, systemImage: "info.circle")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                }

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
        if let q = signalQuality, mode.acquisition != .synthetic {
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

    /// Always-visible badge showing what the deterministic rule table
    /// currently detects, regardless of whether it's actually being applied
    /// to generation ("shadow mode") — unlike `signalBadge`, this is never
    /// gated on `mode.acquisition`, so it's visible and testable on the
    /// synthetic stream too. A lighter background + "(preview)" suffix marks
    /// detection-only; a filled background marks that it's live.
    private var adaptiveBadge: some View {
        let label = adaptiveStateLabel(signalQuality: signalQuality, spectralState: detectedSpectralState)
        return Label(
            adaptiveComplexityEnabled ? "Adaptive: \(label)" : "Adaptive: \(label) (preview)",
            systemImage: "slider.horizontal.3"
        )
        .font(.caption)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Color.secondary.opacity(adaptiveComplexityEnabled ? 0.20 : 0.10))
        .cornerRadius(4)
    }

    /// Mirrors `AdaptiveGenerationCombination`'s priority (`.lost` signal
    /// quality is an absolute floor; otherwise a present spectral opinion
    /// wins over the coarser signal-quality bucket) so the badge text never
    /// disagrees with what's actually detected/applied.
    private func adaptiveStateLabel(signalQuality: SignalQuality?, spectralState: SpectralState?) -> String {
        if signalQuality == .lost { return "Minimal" }
        if let spectralState { return spectralState.badgeLabel }
        switch signalQuality {
        case .none, .healthy: return "Standard"
        case .poor:           return "Simplified"
        case .lost:           return "Minimal"
        }
    }

    /// Deliberately obvious while active — matching the universal hardware
    /// convention for "something is being recorded right now" (a camera/mic
    /// recording light), since this persists content to disk, unlike
    /// `adaptiveBadge`'s preview/live distinction. Not shown at all when
    /// off — there's nothing happening to indicate.
    @ViewBuilder
    private var interactionLogBadge: some View {
        if interactionLoggingEnabled {
            Label("Logging", systemImage: "record.circle.fill")
                .font(.caption)
                .foregroundStyle(.red)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.red.opacity(0.12))
                .cornerRadius(4)
        }
    }

    /// Separate from the word-commit log badge because this opt-in stores
    /// measured EEG-derived features. The visible recorder state is part of
    /// the consent boundary, not merely a diagnostics affordance.
    @ViewBuilder
    private var jepaCaptureBadge: some View {
        if jepaTransitionCaptureEnabled {
            Label("JEPA capture", systemImage: "waveform.badge.record")
                .font(.caption)
                .foregroundStyle(.red)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.red.opacity(0.12))
                .cornerRadius(4)
        }
    }

    /// Distinct from `jepaCaptureBadge`: this feature persists nothing to
    /// disk in either state, so red here means "the demo simulation is
    /// actively running," not "something is being recorded."
    @ViewBuilder
    private var worldModelDemoBadge: some View {
        if worldModelDemoEnabled {
            Label("World Model Demo", systemImage: "cube.transparent")
                .font(.caption)
                .foregroundStyle(.red)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.red.opacity(0.12))
                .cornerRadius(4)
        }
    }

    /// Red while the experimental spoken loop is actively generating + speaking.
    /// Distinct from `voiceBadge`'s "Speaking…" (which reflects the manual Speak
    /// button's `isSpeaking`) — the loop bypasses that flag.
    @ViewBuilder
    private var spokenLoopBadge: some View {
        if spokenGenerationLoopEnabled {
            Label("Spoken loop", systemImage: "waveform.badge.mic")
                .font(.caption)
                .foregroundStyle(.red)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.red.opacity(0.12))
                .cornerRadius(4)
        }
    }

    /// The most consequential badge: while active the mic is capturing AND
    /// transcript text may be leaving the machine (cloud LLM). Explicit
    /// "+ Cloud" + a network icon so the runtime egress is never invisible —
    /// this is the one place the app breaks its "no network at runtime" default.
    @ViewBuilder
    private var hypnagogicLoopBadge: some View {
        if hypnagogicLoopEnabled {
            Label("Listening + Cloud", systemImage: "antenna.radiowaves.left.and.right")
                .font(.caption)
                .foregroundStyle(.red)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.red.opacity(0.18))
                .cornerRadius(4)
        }
    }

    /// Transient, event-driven badge — visible only while the mic is
    /// actually open (push-to-talk held) or speech is playing, and gone the
    /// instant either stops. Deliberately not folded into `PipelineMode`:
    /// voice isn't part of the continuous EEG pipeline, it only meets it at
    /// the composition buffer (see `PipelineMode`'s own doc comment).
    @ViewBuilder
    private var voiceBadge: some View {
        if isDictating {
            Label("Mic", systemImage: "mic.fill")
                .font(.caption)
                .foregroundStyle(.red)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.red.opacity(0.12))
                .cornerRadius(4)
        } else if isSpeaking {
            Label("Speaking…", systemImage: "speaker.wave.2.fill")
                .font(.caption)
                .foregroundStyle(.blue)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.blue.opacity(0.12))
                .cornerRadius(4)
        }
    }

    /// Sibling of `voiceBadge` for the voice command recognizer.
    /// Distinct color (purple) so the user can see at a glance
    /// which mic-driven path is active. Visible only while the
    /// "Hold to Command" button is held — never as a continuous
    /// state.
    @ViewBuilder
    private var cmdBadge: some View {
        if isCommanding {
            Label("Cmd", systemImage: "command")
                .font(.caption)
                .foregroundStyle(.purple)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.purple.opacity(0.12))
                .cornerRadius(4)
        }
    }
}
