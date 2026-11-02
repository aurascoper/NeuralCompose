import Foundation

/// A single multi-channel EEG sample at one moment in time.
///
/// `channels` is stored as `Float` (32-bit) rather than `Double` because
/// downstream Core ML inference expects `Float32` and we'd convert anyway.
/// Two-byte BLE precision (Muse 2 is 12-bit ADC) trivially round-trips through
/// `Float`, so there's no fidelity loss.
public struct EEGSample: Sendable, Hashable {
    /// Source-provided time coordinate in seconds. It is monotonic and never
    /// NaN, but may be Unix epoch time (for a live bridge) or stream-relative
    /// time (for synthetic/playback). Offline consumers must read the recorder
    /// metadata clock declaration rather than infer one globally.
    public let timestamp: TimeInterval

    /// One value per electrode. For Muse 2 this is 4: TP9, AF7, AF8, TP10.
    public let channels: [Float]

    public init(timestamp: TimeInterval, channels: [Float]) {
        self.timestamp = timestamp
        self.channels = channels
    }

    public var channelCount: Int { channels.count }
}
