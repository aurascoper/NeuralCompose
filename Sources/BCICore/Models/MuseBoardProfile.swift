import Foundation

/// Canonical Muse + synthetic board profile abstraction.
///
/// The functional layers (windowing, classifier, UI) talk to `MuseBoardProfile`
/// and never to BrainFlow board IDs directly. If BrainFlow renumbers a board
/// or changes EEG channel ordering for a hardware revision, this file is the
/// single place to update.
///
/// Native BLE vs BLED dongle is now a first-class distinction. Same hardware,
/// different transport, different BrainFlow board ID. The Asus / BLED112
/// dongle path uses the `*BLED*` variants.
///
/// `brainFlowBoardID` matches `brainflow::BoardIds` in BrainFlow 5.x. These
/// integers are *not* a stable ABI in any contractual sense; treat them as
/// implementation detail of this file alone. Verify against the installed
/// BrainFlow headers (`board_shim.h`'s `BoardIds` enum) with
/// `BrainFlowService.debugDumpKnownBoards()`.
public enum MuseBoardProfile: String, Sendable, CaseIterable, Codable, Hashable {

    // Muse 2 (2018+). 4 EEG channels + accel/gyro.
    case museTwoNativeBLE     // Apple's BLE stack
    case museTwoBLED          // BLED112 USB dongle

    // Muse S (2020+). 4 EEG channels + PPG + accel/gyro.
    case museSNativeBLE
    case museSBLED

    // Muse S Athena (2024+). Dedicated board in BrainFlow 5.22+. Native BLE
    // is the recommended transport; BLED is deprecated for new boards.
    //
    // Note on spelling: BrainFlow's 5.22.0 *announcement post* spells the
    // constant `MUSE_S_ANTHENA_BOARD`, but the actual C++ enum in
    // `src/utils/inc/brainflow_constants.h` is `MUSE_S_ATHENA_BOARD`.
    // We follow the source-of-truth enum name and value.
    case museSAthena

    case synthetic           // BrainFlow's built-in synthetic generator
    case playback            // CSV-on-disk

    // Remote Muse over OSC (e.g. a phone running Mind Monitor, relayed over
    // a private VPN such as Tailscale — see MindMonitorOSCStream). This is
    // the one profile that touches the network at runtime; deliberately a
    // distinct, explicitly-labeled case rather than folding into an
    // existing one, so the privacy banner always shows the user which
    // transport is actually live (see PipelineMode.Acquisition.remotePhone).
    case oscRemote

    // MARK: BrainFlow mapping (single source of truth)
    //
    // Reference values from BrainFlow 5.22 `BoardIds`:
    //   MUSE_S_BLED_BOARD       = 21
    //   MUSE_2_BLED_BOARD       = 22
    //   MUSE_2_BOARD            = 38
    //   MUSE_S_BOARD            = 39
    //   MUSE_S_ATHENA_BOARD     = 67  (added in BrainFlow 5.22+;
    //                                  blog spells it MUSE_S_ANTHENA_BOARD,
    //                                  source enum is MUSE_S_ATHENA_BOARD)
    //   OB5000_8_CHANNELS_BOARD = 60  (NOT Muse — do not confuse with Athena)
    //   SYNTHETIC_BOARD         = -1
    //
    // Verified against
    //   brainflow-dev/brainflow@master:src/utils/inc/brainflow_constants.h
    // To re-verify against the installed BrainFlow C++ enum at runtime
    // (without opening any hardware session), call
    // `BrainFlowService.verifyBoardIDsAgainstBridge()` in a debug build.
    public var brainFlowBoardID: Int32? {
        switch self {
        case .museTwoNativeBLE:  return 38   // MUSE_2_BOARD
        case .museTwoBLED:       return 22   // MUSE_2_BLED_BOARD
        case .museSNativeBLE:    return 39   // MUSE_S_BOARD
        case .museSBLED:         return 21   // MUSE_S_BLED_BOARD
        case .museSAthena:       return 67   // MUSE_S_ATHENA_BOARD
        case .synthetic:         return -1   // SYNTHETIC_BOARD
        case .playback:          return nil
        case .oscRemote:         return nil  // not a BrainFlow board at all
        }
    }

    /// EEG channel labels for this profile, in the order BrainFlow yields them.
    public var channelLabels: [String] {
        switch self {
        case .museTwoNativeBLE, .museTwoBLED,
             .museSNativeBLE,   .museSBLED,
             .museSAthena,
             .oscRemote:
            return ["TP9", "AF7", "AF8", "TP10"]
        case .synthetic:
            return ["syn0", "syn1", "syn2", "syn3"]
        case .playback:
            return []        // determined at playback time from CSV header
        }
    }

    public var sampleRate: Double {
        switch self {
        case .museTwoNativeBLE, .museTwoBLED,
             .museSNativeBLE,   .museSBLED,
             .museSAthena,
             .synthetic, .playback,
             .oscRemote:
            return 256.0
        }
    }

    public var displayName: String {
        switch self {
        case .museTwoNativeBLE: return "Muse 2 (BLE)"
        case .museTwoBLED:      return "Muse 2 (BLED112)"
        case .museSNativeBLE:   return "Muse S (BLE)"
        case .museSBLED:        return "Muse S (BLED112)"
        case .museSAthena:      return "Muse S Athena"
        case .synthetic:        return "Synthetic"
        case .playback:         return "Playback"
        case .oscRemote:        return "OSC Remote (network)"
        }
    }

    /// Machine-readable transport label for `metadata.json` and
    /// cross-transport analysis (see the dual-transport comparison notes in
    /// the reliability-hardening roadmap) — coarser than `displayName`:
    /// every BrainFlow-backed Muse profile collapses to `"brainflow"`
    /// regardless of BLE vs. BLED112 dongle, since that distinction doesn't
    /// matter for comparing against the OSC path.
    public var transportLabel: String {
        switch self {
        case .museTwoNativeBLE, .museTwoBLED,
             .museSNativeBLE,   .museSBLED,
             .museSAthena:
            return "brainflow"
        case .oscRemote:
            return "osc"
        case .playback:
            return "playback"
        case .synthetic:
            return "synthetic"
        }
    }

    /// True if this profile requires a physical BrainFlow connection.
    public var requiresBrainFlow: Bool {
        switch self {
        case .museTwoNativeBLE, .museTwoBLED,
             .museSNativeBLE,   .museSBLED,
             .museSAthena,
             .synthetic:
            return true
        case .playback, .oscRemote:
            return false
        }
    }

    /// True if this profile reaches an actual Muse over Bluetooth.
    public var requiresHardware: Bool {
        switch self {
        case .museTwoNativeBLE, .museTwoBLED,
             .museSNativeBLE,   .museSBLED,
             .museSAthena:
            return true
        case .synthetic, .playback, .oscRemote:
            return false
        }
    }

    /// True if this profile reaches the network at runtime — the one
    /// deliberate exception to the "no network at runtime" default. Drives
    /// the privacy banner's explicit network callout.
    public var requiresNetwork: Bool {
        self == .oscRemote
    }

    /// True if this profile uses a BLED112 USB dongle for transport.
    public var usesBLEDDongle: Bool {
        switch self {
        case .museTwoBLED, .museSBLED: return true
        default:                        return false
        }
    }
}
