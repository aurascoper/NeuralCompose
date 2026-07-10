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
    /// computable. `MindMonitorOSCStream` returns `nil` because Mind
    /// Monitor's OSC payload carries no per-packet sequence number to
    /// detect gaps against — not a limitation of this type. A future
    /// transport with sequence numbers (e.g. anything timetag-based) can
    /// populate this field as-is; nothing about its shape assumes OSC.
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
    /// UDP port this transport is listening on, for display (e.g. in the
    /// privacy banner) without grepping the log. `nil` for transports with
    /// no port concept.
    public var boundPort: UInt16?
    /// Best-effort local network interface name serving the most recent
    /// packet (e.g. `utun3` for a Tailscale interface), if the transport
    /// can determine it. This is a sanity check for the user — "does the
    /// traffic look like it's arriving over my VPN, not some other
    /// interface" — not a security boundary; the VPN is still what keeps
    /// unwanted traffic out. `nil` if not yet known or not applicable.
    public var localInterfaceName: String?

    public init(
        transport: String,
        sampleRate: Double = 0,
        packetsReceived: Int = 0,
        packetsDropped: Int = 0,
        packetLossEstimate: Double? = nil,
        packetJitterMillis: Double? = nil,
        lastInterArrivalMillis: Double? = nil,
        lastHeartbeat: Date? = nil,
        boundPort: UInt16? = nil,
        localInterfaceName: String? = nil
    ) {
        self.transport = transport
        self.sampleRate = sampleRate
        self.packetsReceived = packetsReceived
        self.packetsDropped = packetsDropped
        self.packetLossEstimate = packetLossEstimate
        self.packetJitterMillis = packetJitterMillis
        self.lastInterArrivalMillis = lastInterArrivalMillis
        self.lastHeartbeat = lastHeartbeat
        self.boundPort = boundPort
        self.localInterfaceName = localInterfaceName
    }

    /// Seconds since `lastHeartbeat`, computed fresh at access time (not
    /// baked in at construction) — the primitive a "no data for Ns" UI
    /// indicator or a stall watchdog should actually read, since
    /// `lastInterArrivalMillis` reflects the *previous* gap and doesn't
    /// update while the stream is stalled (a stalled stream has no new
    /// packets to compute a new inter-arrival from). `nil` if no packet
    /// has arrived yet.
    public var secondsSinceLastHeartbeat: TimeInterval? {
        guard let lastHeartbeat else { return nil }
        return Date().timeIntervalSince(lastHeartbeat)
    }
}
