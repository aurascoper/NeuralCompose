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
    // is the recommended transport; BLED for Athena is not officially
    // supported as of this writing.
    case museSAthena

    case synthetic           // BrainFlow's built-in synthetic generator
    case playback            // CSV-on-disk

    // MARK: BrainFlow mapping (single source of truth)
    //
    // Reference values from BrainFlow 5.22 `BoardIds`:
    //   MUSE_S_BLED_BOARD       = 21
    //   MUSE_2_BLED_BOARD       = 22
    //   MUSE_2_BOARD            = 38
    //   MUSE_S_BOARD            = 39
    //   MUSE_S_ANTHENA_BOARD    = 60  (added in 5.22.0; verify your install)
    //   SYNTHETIC_BOARD         = -1
    //
    // Run `BrainFlowService.debugDumpKnownBoards()` to print the live values
    // your installed BrainFlow reports for these names.
    public var brainFlowBoardID: Int32? {
        switch self {
        case .museTwoNativeBLE:  return 38   // MUSE_2_BOARD
        case .museTwoBLED:       return 22   // MUSE_2_BLED_BOARD
        case .museSNativeBLE:    return 39   // MUSE_S_BOARD
        case .museSBLED:         return 21   // MUSE_S_BLED_BOARD
        case .museSAthena:       return 60   // MUSE_S_ANTHENA_BOARD — verify!
        case .synthetic:         return -1   // SYNTHETIC_BOARD
        case .playback:          return nil
        }
    }

    /// EEG channel labels for this profile, in the order BrainFlow yields them.
    public var channelLabels: [String] {
        switch self {
        case .museTwoNativeBLE, .museTwoBLED,
             .museSNativeBLE,   .museSBLED,
             .museSAthena:
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
             .synthetic, .playback:
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
        case .playback:
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
        case .synthetic, .playback:
            return false
        }
    }

    /// True if this profile uses a BLED112 USB dongle for transport.
    public var usesBLEDDongle: Bool {
        switch self {
        case .museTwoBLED, .museSBLED: return true
        default:                        return false
        }
    }
}
