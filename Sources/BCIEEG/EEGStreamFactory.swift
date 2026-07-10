import Foundation
import BCICore
import BCIBridge

/// Picks the right `EEGStreaming` implementation for a profile, and yields
/// the actual `PipelineMode.Acquisition`/`Transport` for the privacy banner.
///
/// The single place that decides "is the user actually getting BrainFlow,
/// or did we just transparently fall back to synthetic because the bridge
/// is stubbed?"
public enum EEGStreamFactory {

    public struct Resolved: Sendable {
        public let stream: any EEGStreaming
        public let acquisition: PipelineMode.Acquisition
        public let transport: PipelineMode.Transport
        public let profile: MuseBoardProfile
    }

    public static func make(
        profile: MuseBoardProfile,
        playbackPath: String? = nil,
        oscPort: UInt16 = 5000
    ) -> Resolved {
        switch profile {
        case .oscRemote:
            // The one profile that touches the network at runtime — see
            // MindMonitorOSCStream's doc comment. No stub-mode fallback:
            // unlike BrainFlow (which can transparently degrade to
            // synthetic when the bridge is unavailable), there's no sense
            // in which "OSC remote" silently degrading to synthetic would
            // be anything but confusing — if the user explicitly chose
            // this profile, they should see it fail loudly if the port is
            // already in use, not silently get fake data.
            return Resolved(
                stream: MindMonitorOSCStream(port: oscPort),
                acquisition: .remotePhone,
                transport: .oscUDP,
                profile: .oscRemote
            )

        case .playback:
            if let path = playbackPath {
                return Resolved(
                    stream: PlaybackEEGStream(path: path),
                    acquisition: .playback,
                    transport: .replay,
                    profile: .playback
                )
            }
            BCILog.eeg.notice("Playback profile selected without path; falling back to synthetic")
            return Resolved(
                stream: SyntheticEEGStream(), acquisition: .synthetic, transport: .none, profile: .synthetic
            )

        case .synthetic:
            // The pure-Swift synthetic stream is fully self-contained and
            // friendlier for tests and offline runs than going through the
            // BrainFlow synthetic generator. Prefer it.
            return Resolved(
                stream: SyntheticEEGStream(), acquisition: .synthetic, transport: .none, profile: .synthetic
            )

        case .museTwoNativeBLE, .museTwoBLED,
             .museSNativeBLE,   .museSBLED,
             .museSAthena:
            if bci_bridge_is_available() {
                return Resolved(
                    stream: BrainFlowService(profile: profile),
                    acquisition: .localMuse,
                    transport: .ble,
                    profile: profile
                )
            }
            BCILog.eeg.notice(
                "Bridge unavailable (BCI_BRAINFLOW_AVAILABLE not set); falling back to synthetic"
            )
            return Resolved(
                stream: SyntheticEEGStream(), acquisition: .synthetic, transport: .none, profile: .synthetic
            )
        }
    }

    /// Construct a synthetic-only resolved value. Used by `AppViewModel`'s
    /// runtime supervisor when a live stream throws and we want to keep the
    /// session alive in degraded mode.
    public static func makeSynthetic() -> Resolved {
        Resolved(stream: SyntheticEEGStream(), acquisition: .synthetic, transport: .none, profile: .synthetic)
    }
}
