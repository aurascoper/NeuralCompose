import Foundation

/// Transport-level health metrics for a live EEG stream — deliberately
/// separate from `EEGSample` (see `EEGStreaming`'s frozen-API doc comment).
/// Diagnostics are a transport concern, not part of the sample payload
/// every consumer (windowing, classifier, 3D workspace, the regression
/// suite) has to know about; keeping them out of `EEGSample` means adding
/// a new transport never touches that struct's shape or any of its
/// existing call sites.
///
/// Only network transports populate this meaningfully today
/// (`MindMonitorOSCStream`). Local transports (BrainFlow BLE, synthetic,
/// CSV playback) have no packet-loss/jitter concept in the same sense —
/// they're not expected to construct one at all, rather than fabricating
/// numbers that don't mean anything for a local connection.
public struct StreamDiagnostics: Sendable, Equatable {
    /// Human-readable transport identifier for display, e.g. "OSC (Mind Monitor)".
    public var transport: String
    public var sampleRate: Double
    public var packetsReceived: Int
    /// Packets received but not turned into an `EEGSample` — malformed OSC,
    /// or a `/muse/*` address this decoder doesn't map yet (e.g. `/muse/acc`).
    public var packetsDropped: Int
    /// Estimated packet loss as a 0...1 fraction, or `nil` if it isn't
    /// computable. Mind Monitor's OSC stream carries no sequence numbers,
    /// so there's no gap to detect against — this stays `nil` for
    /// `MindMonitorOSCStream` today rather than reporting a fabricated 0%.
    public var packetLossEstimate: Double?
    /// Standard deviation of inter-packet arrival intervals over a short
    /// rolling window, in milliseconds — a jitter proxy computed entirely
    /// from local wall-clock arrival times.
    public var packetJitterMillis: Double?
    /// Milliseconds since the previous packet's arrival, as of the most
    /// recent packet. This is *not* one-way network latency — measuring
    /// true one-way latency needs clock sync between the phone and the Mac,
    /// which OSC/UDP doesn't provide. It's a local staleness/cadence
    /// signal: consistently near `1000/sampleRate` means healthy delivery.
    public var lastInterArrivalMillis: Double?
    /// Wall-clock time the most recent packet arrived, for a UI staleness
    /// indicator ("no data for Ns").
    public var lastHeartbeat: Date?

    public init(
        transport: String,
        sampleRate: Double = 0,
        packetsReceived: Int = 0,
        packetsDropped: Int = 0,
        packetLossEstimate: Double? = nil,
        packetJitterMillis: Double? = nil,
        lastInterArrivalMillis: Double? = nil,
        lastHeartbeat: Date? = nil
    ) {
        self.transport = transport
        self.sampleRate = sampleRate
        self.packetsReceived = packetsReceived
        self.packetsDropped = packetsDropped
        self.packetLossEstimate = packetLossEstimate
        self.packetJitterMillis = packetJitterMillis
        self.lastInterArrivalMillis = lastInterArrivalMillis
        self.lastHeartbeat = lastHeartbeat
    }
}
