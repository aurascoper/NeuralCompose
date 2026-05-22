import Foundation

/// Canonical Muse + synthetic board profile abstraction.
///
/// The functional layers (windowing, classifier, UI) talk to `MuseBoardProfile`
/// and never to BrainFlow board IDs directly. If BrainFlow renumbers a board
/// or changes EEG channel ordering for a hardware revision, this file is the
/// single place to update.
///
/// `brainFlowBoardID` matches `brainflow::BoardIds` in BrainFlow 5.x. These
/// integers are *not* a stable ABI in any contractual sense; treat them as
/// implementation detail of this file alone.
public enum MuseBoardProfile: String, Sendable, CaseIterable, Codable, Hashable {
    /// Muse 2 (2018+). 4 EEG channels + accel/gyro. Classic Muse BLE.
    case museTwo

    /// Muse S (2020+). 4 EEG channels + PPG + accel/gyro.
    case museS

    /// Muse S Athena (2024+). Updated firmware + new BLE protocol; we route
    /// over a dedicated USB-BT dongle for stability.
    case museSAthena

    /// BrainFlow synthetic generator. No hardware needed.
    case synthetic

    /// CSV-on-disk playback. No hardware needed.
    case playback

    // MARK: BrainFlow mapping (single source of truth)

    /// BrainFlow `BoardIds` integer for this profile. Returns -1 for synthetic
    /// (matches BrainFlow's `SYNTHETIC_BOARD`) and `nil` for `.playback`,
    /// which doesn't go through BrainFlow at all.
    public var brainFlowBoardID: Int32? {
        switch self {
        case .museTwo:      return 22    // MUSE_2_BOARD
        case .museS:        return 39    // MUSE_S_BOARD
        case .museSAthena:  return 51    // MUSE_S_BLED_BOARD / Athena variant
        case .synthetic:    return -1    // SYNTHETIC_BOARD
        case .playback:     return nil
        }
    }

    /// EEG channel labels for this profile, in the order BrainFlow yields them.
    public var channelLabels: [String] {
        switch self {
        case .museTwo, .museS, .museSAthena:
            return ["TP9", "AF7", "AF8", "TP10"]
        case .synthetic:
            return ["syn0", "syn1", "syn2", "syn3"]
        case .playback:
            // Determined at playback time from CSV header.
            return []
        }
    }

    /// Native sample rate (Hz).
    public var sampleRate: Double {
        switch self {
        case .museTwo, .museS, .museSAthena: return 256.0
        case .synthetic:                     return 256.0
        case .playback:                      return 256.0
        }
    }

    public var displayName: String {
        switch self {
        case .museTwo:     return "Muse 2"
        case .museS:       return "Muse S"
        case .museSAthena: return "Muse S Athena"
        case .synthetic:   return "Synthetic"
        case .playback:    return "Playback"
        }
    }

    /// True if this profile requires a physical BrainFlow connection. Lets the
    /// stream factory short-circuit the BrainFlow path when not needed.
    public var requiresBrainFlow: Bool {
        switch self {
        case .museTwo, .museS, .museSAthena, .synthetic: return true
        case .playback:                                   return false
        }
    }

    /// True if this profile reaches an actual Muse over Bluetooth.
    public var requiresHardware: Bool {
        switch self {
        case .museTwo, .museS, .museSAthena: return true
        case .synthetic, .playback:          return false
        }
    }
}
