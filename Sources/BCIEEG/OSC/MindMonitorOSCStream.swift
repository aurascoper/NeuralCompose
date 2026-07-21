import Foundation
import Network
import BCICore

/// `EEGStreaming` conformer that receives Muse EEG samples over OSC/UDP
/// from Mind Monitor (an Android/iOS app that streams a paired Muse
/// headband's raw EEG as OSC packets).
///
/// This is the one `EEGStreaming` conformer that touches the network at
/// runtime — see `MuseBoardProfile.requiresNetwork` and
/// `PipelineMode.Acquisition.remotePhone`. It is meant to be reached only over a
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
///     UDP datagram -> MuseOSCDecoder (generic OSC, incl. bundle
///         unwrapping) -> MindMonitorDecoder (Mind Monitor semantics)
///         -> EEGSample
///
/// This class owns exactly the networking (`NWListener`/`NWConnection`)
/// and the diagnostics bookkeeping (arrival timing, packet counts) — see
/// `MuseOSCDecoder` and `MindMonitorDecoder` for the decoding, which is
/// independently unit-testable without a socket.
public final class MindMonitorOSCStream: EEGStreaming, MovementStreaming, @unchecked Sendable {

    public let profile: MuseBoardProfile = .oscRemote
    public private(set) var effectiveSampleRate: Double = 256.0
    public let channelCount: Int = 4

    /// Parallel accel/gyro channel (see `MovementStreaming`). Created ONCE in
    /// init and never re-created or finished per `start()`, so it survives the
    /// supervisor's stop()/start() reconnect cycles; a bounded buffer keeps an
    /// un-drained channel from growing without limit. `movementContinuation.yield`
    /// is thread-safe (like the EEG continuation), so it's called outside `lock`.
    public let movementStream: AsyncStream<MovementSample>
    private let movementContinuation: AsyncStream<MovementSample>.Continuation

    private let port: NWEndpoint.Port
    private let staleTimeoutSec: Double
    private let lock = NSLock()
    private var listener: NWListener?
    private var startNanos: UInt64?
    private var watchdogTask: Task<Void, Never>?

    // Diagnostics bookkeeping — see `currentDiagnostics()`.
    private var lastArrivalNanos: UInt64?
    private var interArrivalMillis: [Double] = []
    private let interArrivalWindow = 64
    private var packetsReceived = 0
    private var packetsDropped = 0
    private var movementYielded = 0
    private var movementBufferDropped = 0
    private var ignoredNonEEG = 0
    private var samplesYielded = 0
    private var lastHeartbeat: Date?
    /// Wall-clock of the most recent *EEG sample* actually yielded — distinct
    /// from `lastHeartbeat` (any datagram). The stall watchdog keys off THIS so
    /// that continuing non-EEG traffic (`/muse/acc`, `/muse/gyro`, `/muse/batt`)
    /// can't hold the link "alive" while the `/muse/eeg` substream is silently
    /// dead (electrodes lifted, EEG toggled off).
    private var lastSampleWallClock: Date?
    /// Best-effort — set from the most recent connection's `NWPath`, once
    /// that path resolves. `nil` until the first connection reports a path,
    /// which can lag the first received packet slightly.
    private var localInterfaceName: String?

    /// - Parameters:
    ///   - port: UDP port to listen on. Must match the "OSC Port"
    ///     configured in Mind Monitor's settings. Default matches
    ///     `HARDWARE_SETUP.md`'s documented convention for this project.
    ///   - staleTimeoutSec: If no *EEG sample* is produced for longer than this,
    ///     the stream finishes with `.streamFailed` instead of waiting on
    ///     `receiveMessage` forever. Keyed to EEG-sample throughput, not raw
    ///     packet arrival, so continuing non-EEG traffic (`/muse/acc` etc.)
    ///     can't mask a dead `/muse/eeg` substream. Same failure mode as
    ///     `BrainFlowService`'s equivalent watchdog: a phone that stops
    ///     sending (backgrounded, out of Tailscale range, Mind Monitor
    ///     killed) never causes an `NWConnection` error — the
    ///     `receiveMessage` callback just never fires again — so without
    ///     this, `AppViewModel`'s retry/backoff/reconnecting-UI supervisor,
    ///     which only reacts to the stream throwing or finishing, never
    ///     fires either. Default matches `BrainFlowService`'s 5s.
    public init(port: UInt16 = 5000, staleTimeoutSec: Double = 5.0) {
        self.port = NWEndpoint.Port(rawValue: port) ?? 5000
        self.staleTimeoutSec = staleTimeoutSec
        // Bounded buffer: if nothing drains the movement channel, keep only the
        // most recent samples rather than growing unbounded at the IMU rate.
        var cont: AsyncStream<MovementSample>.Continuation!
        self.movementStream = AsyncStream(bufferingPolicy: .bufferingNewest(256)) { cont = $0 }
        self.movementContinuation = cont
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
                connection.pathUpdateHandler = { [weak self] path in
                    self?.recordLocalInterfaceName(path.availableInterfaces.first?.name)
                }
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

            let sessionStart = Date()
            let watchdog = Task { [weak self] in
                guard let self else { return }
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    if Task.isCancelled { break }
                    // Key the watchdog off EEG-SAMPLE throughput, not raw packet
                    // arrival: continuing non-EEG traffic (/muse/acc, gyro, batt)
                    // must NOT keep the link "alive" while /muse/eeg has stopped.
                    let staleness = self.secondsSinceLastSample(sessionStart: sessionStart)
                    if staleness > self.staleTimeoutSec {
                        // Distinguish a fully dead link (no datagrams at all) from
                        // an EEG-substream stall (packets still arriving, but no
                        // /muse/eeg samples). Both are failures the supervisor must
                        // act on; the message names the likely cause.
                        let packetsAlsoStopped =
                            self.secondsSinceLastHeartbeat(sessionStart: sessionStart) > self.staleTimeoutSec
                        let reason = packetsAlsoStopped
                            ? "no OSC packets received for \(Int(staleness))s — link likely dead"
                            : "no EEG samples for \(Int(staleness))s while other OSC traffic continues — EEG substream stalled (electrodes lifted or EEG stream off)"
                        BCILog.eeg.error(
                            "MindMonitorOSCStream: \(reason, privacy: .public) (>\(self.staleTimeoutSec, format: .fixed(precision: 1))s timeout)"
                        )
                        continuation.finish(throwing: BCIError.streamFailed(reason: reason))
                        return
                    }
                }
            }
            self.recordWatchdogTask(watchdog)

            continuation.onTermination = { @Sendable [weak self] _ in
                newListener.cancel()
                self?.cancelWatchdog()
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
        // Reset the per-session timing references. The supervisor reuses ONE
        // stream instance across live retries (stop()/start() in a loop), so a
        // reconnect must measure staleness from THIS attempt's sessionStart, not
        // inherit the prior attempt's last sample/heartbeat — otherwise the
        // sample watchdog's reconnect grace collapses to a single ~1s tick and
        // tears down an otherwise-recoverable link. lastArrivalNanos is cleared
        // too so the first post-restart inter-arrival isn't a cross-session gap.
        self.lastSampleWallClock = nil
        self.lastHeartbeat = nil
        self.lastArrivalNanos = nil
    }

    @discardableResult
    private func takeListenerForStop() -> NWListener? {
        lock.lock()
        defer { lock.unlock() }
        let current = listener
        listener = nil
        return current
    }

    private func recordLocalInterfaceName(_ name: String?) {
        guard let name else { return }
        lock.lock()
        defer { lock.unlock() }
        localInterfaceName = name
    }

    private func recordWatchdogTask(_ task: Task<Void, Never>) {
        lock.lock()
        defer { lock.unlock() }
        watchdogTask = task
    }

    private func cancelWatchdog() {
        lock.lock()
        let task = watchdogTask
        watchdogTask = nil
        lock.unlock()
        task?.cancel()
    }

    /// `lastHeartbeat` starts `nil` (no packet has arrived yet), so a
    /// stream that never receives its first packet is measured against
    /// `sessionStart` rather than reporting `nil`/never-stale.
    private func secondsSinceLastHeartbeat(sessionStart: Date) -> Double {
        lock.lock()
        defer { lock.unlock() }
        let reference = lastHeartbeat ?? sessionStart
        return Date().timeIntervalSince(reference)
    }

    /// EEG-sample staleness for the watchdog. Like `secondsSinceLastHeartbeat`
    /// but measured from the last *yielded EEG sample*, so a link still
    /// delivering non-EEG OSC messages while `/muse/eeg` has stopped is detected
    /// as stale. `nil` (no sample yet) measures against `sessionStart`, so a
    /// stream that never produces a first EEG sample still fails after the timeout.
    private func secondsSinceLastSample(sessionStart: Date) -> Double {
        lock.lock()
        defer { lock.unlock() }
        let reference = lastSampleWallClock ?? sessionStart
        return Date().timeIntervalSince(reference)
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

    /// True for addresses this transport is expected to decode into a sample —
    /// so a nil decode at one of them means truncation/corruption (a real drop),
    /// not benign non-sample traffic.
    private func isKnownSampleAddress(_ address: String) -> Bool {
        address == MindMonitorDecoder.eegAddress
            || address == MindMonitorDecoder.accelAddress
            || address == MindMonitorDecoder.gyroAddress
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
            // Mind Monitor wraps every message in an OSC bundle, even a
            // single one — decodePacket() unwraps that transparently.
            let messages = try MuseOSCDecoder.decodePacket(data)
            for message in messages {
                if let sample = MindMonitorDecoder.sample(from: message, timestamp: elapsedSeconds) {
                    lock.lock(); samplesYielded += 1; lastSampleWallClock = Date(); lock.unlock()
                    continuation.yield(sample)
                } else if let movement = MindMonitorDecoder.movement(from: message, timestamp: elapsedSeconds) {
                    // /muse/acc + /muse/gyro → the parallel movement channel, NOT
                    // a drop (review finding H2). yield is thread-safe, so unlocked.
                    // Capture the YieldResult: a full bounded buffer silently evicts
                    // the OLDEST sample, so count that as a drop rather than masking
                    // it (movementYielded would otherwise count production, not delivery).
                    switch movementContinuation.yield(movement) {
                    case .enqueued:
                        lock.lock(); movementYielded += 1; lock.unlock()
                    case .dropped:
                        lock.lock(); movementBufferDropped += 1; let n = movementBufferDropped; lock.unlock()
                        if n == 1 || n % 256 == 0 {
                            BCILog.eeg.notice("MindMonitorOSCStream: movement buffer full — dropped \(n, privacy: .public) IMU sample(s) (drain stalled)")
                        }
                    case .terminated: break
                    @unknown default: break
                    }
                } else if isKnownSampleAddress(message.address) {
                    // A known EEG/movement address whose decode returned nil — i.e.
                    // a TRUNCATED /muse/eeg (<4 floats) or /muse/acc|gyro (<3): genuine
                    // corruption, not benign traffic. Log + count as a real drop so
                    // H2's "no false loss" doesn't invert into "hidden real loss".
                    BCILog.eeg.error("MindMonitorOSCStream: malformed \(message.address, privacy: .public) message (too few values) — counted as dropped")
                    lock.lock(); packetsDropped += 1; lock.unlock()
                } else {
                    // Genuinely non-sample address (/muse/batt, /muse/elements, …):
                    // expected traffic, deliberately kept out of packetsDropped so
                    // it can't masquerade as packet loss.
                    lock.lock(); ignoredNonEEG += 1; lock.unlock()
                }
            }
        } catch {
            // A genuinely malformed datagram (decode threw) — the only real
            // packet-loss/corruption signal.
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
            movementYielded: movementYielded,
            movementBufferDropped: movementBufferDropped,
            ignoredNonEEG: ignoredNonEEG,
            samplesYielded: samplesYielded,
            packetLossEstimate: nil, // no sequence numbers in Mind Monitor's OSC stream to detect gaps against
            packetJitterMillis: jitter,
            lastInterArrivalMillis: interArrivalMillis.last,
            lastHeartbeat: lastHeartbeat,
            boundPort: port.rawValue,
            localInterfaceName: localInterfaceName
        )
    }
}
