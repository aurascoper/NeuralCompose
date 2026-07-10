import Foundation
import Network
import BCICore

/// `EEGStreaming` conformer that receives Muse EEG samples over OSC/UDP
/// from Mind Monitor (an Android/iOS app that streams a paired Muse
/// headband's raw EEG as OSC packets).
///
/// This is the one `EEGStreaming` conformer that touches the network at
/// runtime — see `MuseBoardProfile.requiresNetwork` and
/// `PipelineMode.Source.oscRemote`. It is meant to be reached only over a
/// private VPN interface (e.g. Tailscale) between the phone and this Mac,
/// never over the public internet: OSC has no authentication or encryption
/// of its own, so exposing this port publicly would let anyone on the
/// internet inject arbitrary "EEG" samples into the pipeline.
///
/// Binds to `0.0.0.0` (all interfaces) on the configured UDP port — that's
/// necessary, not a bug: a VPN like Tailscale creates a virtual interface
/// with an IP not known in advance, and a UDP listener has to bind broadly
/// to receive on it. The privacy/security boundary here is "only reachable
/// devices can reach this port," which is Tailscale's job, not this
/// class's. `start()` logs the bound port at `.notice` so this is always
/// visible, not silent.
///
/// ## Design
///
/// Packet decoding is deliberately *not* this class's job:
///
///     UDP datagram -> MuseOSCDecoder (generic OSC) -> MindMonitorDecoder
///         (Mind Monitor semantics) -> EEGSample
///
/// This class owns exactly the networking (`NWListener`/`NWConnection`)
/// and the diagnostics bookkeeping (arrival timing, packet counts) — see
/// `MuseOSCDecoder` and `MindMonitorDecoder` for the decoding, which is
/// independently unit-testable without a socket.
public final class MindMonitorOSCStream: EEGStreaming, @unchecked Sendable {

    public let profile: MuseBoardProfile = .oscRemote
    public private(set) var effectiveSampleRate: Double = 256.0
    public let channelCount: Int = 4

    private let port: NWEndpoint.Port
    private let lock = NSLock()
    private var listener: NWListener?
    private var startNanos: UInt64?

    // Diagnostics bookkeeping — see `currentDiagnostics()`.
    private var lastArrivalNanos: UInt64?
    private var interArrivalMillis: [Double] = []
    private let interArrivalWindow = 64
    private var packetsReceived = 0
    private var packetsDropped = 0
    private var lastHeartbeat: Date?

    /// - Parameter port: UDP port to listen on. Must match the "OSC Port"
    ///   configured in Mind Monitor's settings. Default matches
    ///   `HARDWARE_SETUP.md`'s documented convention for this project.
    public init(port: UInt16 = 5000) {
        self.port = NWEndpoint.Port(rawValue: port) ?? 5000
    }

    public func start() async throws -> AsyncThrowingStream<EEGSample, any Error> {
        try checkNotAlreadyStarted()

        let newListener: NWListener
        do {
            newListener = try NWListener(using: .udp, on: port)
        } catch {
            throw BCIError.streamConnectFailed(
                profile: profile,
                underlying: "UDP bind on port \(port.rawValue) failed: \(error.localizedDescription)"
            )
        }

        recordStarted(newListener, startNanos: DispatchTime.now().uptimeNanoseconds)

        BCILog.eeg.notice(
            "MindMonitorOSCStream listening on UDP port \(self.port.rawValue, privacy: .public) (all interfaces) — reach this only via a private VPN (e.g. Tailscale), never the public internet"
        )

        return AsyncThrowingStream<EEGSample, any Error> { continuation in
            newListener.newConnectionHandler = { [weak self] connection in
                guard let self else { return }
                connection.start(queue: .global(qos: .userInitiated))
                self.receiveLoop(on: connection, continuation: continuation)
            }
            newListener.stateUpdateHandler = { state in
                switch state {
                case .failed(let error):
                    continuation.finish(throwing: BCIError.streamFailed(reason: "OSC listener failed: \(error)"))
                case .cancelled:
                    continuation.finish()
                default:
                    break
                }
            }
            newListener.start(queue: .global(qos: .userInitiated))
            continuation.onTermination = { @Sendable _ in
                newListener.cancel()
            }
        }
    }

    public func stop() async {
        takeListenerForStop()?.cancel()
    }

    // MARK: - Locking helpers
    //
    // NSLock.lock()/.unlock() can't be called directly inside an `async`
    // function under strict concurrency (they're flagged as unsafe —
    // Swift wants async-safe scoped locking instead). These stay plain
    // synchronous methods so start()/stop() call into them rather than
    // locking inline.

    private func checkNotAlreadyStarted() throws {
        lock.lock()
        defer { lock.unlock() }
        guard listener == nil else {
            throw BCIError.streamFailed(reason: "MindMonitorOSCStream.start() called twice on the same instance")
        }
    }

    private func recordStarted(_ newListener: NWListener, startNanos: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        self.listener = newListener
        self.startNanos = startNanos
    }

    @discardableResult
    private func takeListenerForStop() -> NWListener? {
        lock.lock()
        defer { lock.unlock() }
        let current = listener
        listener = nil
        return current
    }

    // MARK: - Receiving

    private func receiveLoop(
        on connection: NWConnection,
        continuation: AsyncThrowingStream<EEGSample, any Error>.Continuation
    ) {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let error {
                BCILog.eeg.error("MindMonitorOSCStream connection error: \(String(describing: error))")
                connection.cancel()
                return
            }
            if let data, !data.isEmpty {
                self.handlePacket(data, continuation: continuation)
            }
            self.receiveLoop(on: connection, continuation: continuation)
        }
    }

    private func handlePacket(
        _ data: Data,
        continuation: AsyncThrowingStream<EEGSample, any Error>.Continuation
    ) {
        let nowNanos = DispatchTime.now().uptimeNanoseconds

        lock.lock()
        let previousArrival = lastArrivalNanos
        lastArrivalNanos = nowNanos
        packetsReceived += 1
        lastHeartbeat = Date()
        if let previousArrival {
            let intervalMillis = Double(nowNanos &- previousArrival) / 1_000_000.0
            interArrivalMillis.append(intervalMillis)
            if interArrivalMillis.count > interArrivalWindow {
                interArrivalMillis.removeFirst()
            }
        }
        let start = startNanos ?? nowNanos
        lock.unlock()

        let elapsedSeconds = Double(nowNanos &- start) / 1_000_000_000.0

        do {
            let message = try MuseOSCDecoder.decode(data)
            if let sample = MindMonitorDecoder.sample(from: message, timestamp: elapsedSeconds) {
                continuation.yield(sample)
            } else {
                lock.lock(); packetsDropped += 1; lock.unlock()
            }
        } catch {
            BCILog.eeg.error("MindMonitorOSCStream: dropped malformed OSC packet: \(String(describing: error))")
            lock.lock(); packetsDropped += 1; lock.unlock()
        }
    }

    // MARK: - Diagnostics

    /// Current transport health snapshot — see `StreamDiagnostics`.
    public func currentDiagnostics() -> StreamDiagnostics {
        lock.lock()
        defer { lock.unlock() }

        let jitter: Double?
        if interArrivalMillis.count >= 2 {
            let mean = interArrivalMillis.reduce(0, +) / Double(interArrivalMillis.count)
            let variance = interArrivalMillis.reduce(0) { $0 + ($1 - mean) * ($1 - mean) }
                / Double(interArrivalMillis.count)
            jitter = variance.squareRoot()
        } else {
            jitter = nil
        }

        return StreamDiagnostics(
            transport: "OSC (Mind Monitor)",
            sampleRate: effectiveSampleRate,
            packetsReceived: packetsReceived,
            packetsDropped: packetsDropped,
            packetLossEstimate: nil, // no sequence numbers in Mind Monitor's OSC stream to detect gaps against
            packetJitterMillis: jitter,
            lastInterArrivalMillis: interArrivalMillis.last,
            lastHeartbeat: lastHeartbeat
        )
    }
}
