import Foundation

/// The five conventional EEG frequency bands, with the edge frequencies
/// Mind Monitor documents for its `/muse/elements/*_absolute` streams.
/// Using Mind Monitor's edges (not a textbook's) is deliberate: the
/// biofeedback egress advertises itself as a drop-in for Mind Monitor's
/// OSC output, so the band definitions must match what downstream
/// patches were tuned against. Note the documented theta/alpha overlap
/// at 7.5 to 8 Hz; it is reproduced, not corrected.
///
/// Source: Mind Monitor FAQ, "Absolute Band Powers" table
/// (https://mind-monitor.com/FAQ.php).
public enum EEGBand: String, Sendable, Hashable, Codable, CaseIterable {
    case delta
    case theta
    case alpha
    case beta
    case gamma

    /// Half-open band edges in Hz: a PSD bin at frequency `f` belongs to
    /// the band when `lowHz <= f < highHz`.
    public var lowHz: Double {
        switch self {
        case .delta: return 1.0
        case .theta: return 4.0
        case .alpha: return 7.5
        case .beta:  return 13.0
        case .gamma: return 30.0
        }
    }

    public var highHz: Double {
        switch self {
        case .delta: return 4.0
        case .theta: return 8.0
        case .alpha: return 13.0
        case .beta:  return 30.0
        case .gamma: return 44.0
        }
    }

    /// The Mind Monitor OSC address for this band's absolute power.
    public var mindMonitorAbsoluteAddress: String {
        "/muse/elements/\(rawValue)_absolute"
    }
}
