import Foundation
import BCICore
import BCIBridge

/// Picks the right `EEGStreaming` implementation for a profile, and yields
/// the actual `PipelineMode.Source` for the privacy banner.
///
/// The single place that decides "is the user actually getting BrainFlow,
/// or did we just transparently fall back to synthetic because the bridge
/// is stubbed?"
public enum EEGStreamFactory {

    public struct Resolved: Sendable {
        public let stream: any EEGStreaming
        public let source: PipelineMode.Source
        public let profile: MuseBoardProfile
    }

    public static func make(
        profile: MuseBoardProfile,
        playbackPath: String? = nil
    ) -> Resolved {
        switch profile {
        case .playback:
            if let path = playbackPath {
                return Resolved(
                    stream: PlaybackEEGStream(path: path),
                    source: .playback,
                    profile: .playback
                )
            }
            // No path supplied — fall back to synthetic.
            BCILog.eeg.notice("Playback profile selected without path; falling back to synthetic")
            return Resolved(
                stream: SyntheticEEGStream(),
                source: .synthetic,
                profile: .synthetic
            )

        case .synthetic:
            // Even synthetic *could* route through BrainFlow's synthetic
            // generator if the bridge is available — but the pure-Swift
            // synthetic stream is fully self-contained and friendlier for
            // tests and offline runs. Prefer it.
            return Resolved(
                stream: SyntheticEEGStream(),
                source: .synthetic,
                profile: .synthetic
            )

        case .museTwo, .museS, .museSAthena:
            if bci_bridge_is_available() {
                return Resolved(
                    stream: BrainFlowService(profile: profile),
                    source: .brainflowMuse,
                    profile: profile
                )
            }
            BCILog.eeg.notice(
                "Bridge unavailable (BCI_BRAINFLOW_AVAILABLE not set); falling back to synthetic"
            )
            return Resolved(
                stream: SyntheticEEGStream(),
                source: .synthetic,
                profile: .synthetic
            )
        }
    }
}
