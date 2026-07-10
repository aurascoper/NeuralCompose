import Foundation
import BCICore
import BCIBridge

/// Real-device EEG source backed by the BrainFlow C++ library via `BCIBridge`.
///
/// All knowledge of board IDs, BLE quirks, the ASUS USB-BT dongle workaround,
/// and the Muse S Athena updated-firmware path lives here and in
/// `MuseBoardProfile`. The rest of the codebase is unaware of BrainFlow.
///
/// If the bridge is stubbed (no BrainFlow installed), `start()` throws
/// `BCIError.bridgeUnavailable` and the factory falls back to synthetic.
public final class BrainFlowService: EEGStreaming, @unchecked Sendable {

    public let profile: MuseBoardProfile
    public private(set) var effectiveSampleRate: Double
    public private(set) var channelCount: Int

    private let pollIntervalSec: Double
    private let staleTimeoutSec: Double
    private let serialPort: String?
    private let macAddress: String?

    private let lock = NSLock()
    private var handle: bci_session_handle_t?
    private var pollTask: Task<Void, Never>?

    /// - Parameter staleTimeoutSec: If no samples are drained for longer
    ///   than this, the stream finishes with `.streamFailed` instead of
    ///   polling forever. `bci_bridge_drain_samples` returning `BCI_OK`
    ///   with zero samples is BrainFlow's normal "nothing new yet"
    ///   response — indistinguishable, at the status-code level, from a
    ///   BLE link that has silently died (device out of range, powered
    ///   off, or Muse's own ~30s poor-signal auto-shutoff). Without this,
    ///   a silent disconnect never throws or completes, so
    ///   `AppViewModel`'s retry/backoff/fallback-to-synthetic supervisor
    ///   — which only reacts to the stream throwing or finishing — never
    ///   fires, and the UI's last-known channel health/signal-quality
    ///   state freezes indefinitely with no indication it's stale. 5s
    ///   default: long enough that normal per-poll jitter never
    ///   false-positives, short enough to catch a real stall well before
    ///   the Muse's own 30s auto-shutoff.
    public init(
        profile: MuseBoardProfile,
        pollIntervalSec: Double = 0.05,
        staleTimeoutSec: Double = 5.0,
        serialPort: String? = nil,
        macAddress: String? = nil
    ) {
        self.profile = profile
        self.pollIntervalSec = pollIntervalSec
        self.staleTimeoutSec = staleTimeoutSec
        self.serialPort = serialPort
        self.macAddress = macAddress
        self.effectiveSampleRate = profile.sampleRate
        self.channelCount = profile.channelLabels.count
    }

    public func start() async throws -> AsyncThrowingStream<EEGSample, any Error> {
        guard bci_bridge_is_available() else {
            throw BCIError.bridgeUnavailable(reason: "BCIBridge compiled in stub mode")
        }
        guard let boardID = profile.brainFlowBoardID else {
            throw BCIError.streamConnectFailed(
                profile: profile,
                underlying: "profile has no BrainFlow board id"
            )
        }
        let paramsJSON = makeParamsJSON()
        BCILog.eeg.debug("BrainFlow: boardID=\(boardID), profile=\(self.profile.displayName)")

        var newHandle: bci_session_handle_t?
        let status = bci_bridge_create_session(boardID, paramsJSON, &newHandle)
        let statusCode = Int32(status.rawValue)
        BCILog.eeg.debug("BrainFlow: prepare_session completed with status=\(statusCode)")

        guard status == BCI_OK, let h = newHandle else {
            throw BCIError.streamConnectFailed(profile: self.profile, underlying: "status \(status.rawValue)")
        }
        let bridgeCh  = bci_bridge_eeg_channel_count(h)
        let bridgeSR  = bci_bridge_sample_rate(h)
        if bridgeCh > 0 { self.channelCount = Int(bridgeCh) }
        if bridgeSR > 0 { self.effectiveSampleRate = bridgeSR }
        BCILog.eeg.debug("BrainFlow: channels=\(self.channelCount), sampleRate=\(self.effectiveSampleRate) Hz")

        let startStatus = bci_bridge_start_stream(h, 30)
        guard startStatus == BCI_OK else {
            bci_bridge_destroy_session(h)
            throw BCIError.streamConnectFailed(profile: self.profile, underlying: "start_stream \(startStatus.rawValue)")
        }
        BCILog.eeg.notice("BrainFlow stream started: \(self.profile.displayName)")
        self.lock.withLock { self.handle = h }

        let cc = channelCount
        let poll = pollIntervalSec
        let staleTimeout = staleTimeoutSec

        return AsyncThrowingStream<EEGSample, any Error> { continuation in
            let task = Task.detached(priority: .userInitiated) { [weak self] in
                let maxBatch: Int32 = 1024
                let bufLen = Int(maxBatch) * cc
                let samplesBuf = UnsafeMutablePointer<Float>.allocate(capacity: bufLen)
                let tsBuf      = UnsafeMutablePointer<Double>.allocate(capacity: Int(maxBatch))
                defer {
                    samplesBuf.deallocate()
                    tsBuf.deallocate()
                }
                var sampleCount = 0
                var lastLogTime = Date()
                var lastSampleAt = Date()
                while !Task.isCancelled {
                    guard let self = self,
                          let handle = (self.lock.withLock { self.handle }) else {
                        continuation.finish(throwing: BCIError.streamFailed(reason: "handle invalidated"))
                        return
                    }
                    var got: Int32 = 0
                    let st = bci_bridge_drain_samples(handle, samplesBuf, tsBuf, maxBatch, &got)
                    if st != BCI_OK {
                        continuation.finish(throwing: BCIError.streamFailed(reason: "drain status \(st)"))
                        return
                    }
                    if got > 0 {
                        lastSampleAt = Date()
                        sampleCount += Int(got)
                        let now = Date()
                        if now.timeIntervalSince(lastLogTime) >= 1.0 {
                            BCILog.eeg.debug("BrainFlow: \(sampleCount) samples, rate=\(Double(sampleCount) / now.timeIntervalSince(lastLogTime)) Hz")
                            lastLogTime = now
                            sampleCount = 0
                        }
                        for i in 0..<Int(got) {
                            var ch: [Float] = []
                            ch.reserveCapacity(cc)
                            for c in 0..<cc {
                                ch.append(samplesBuf[i * cc + c])
                            }
                            continuation.yield(EEGSample(timestamp: tsBuf[i], channels: ch))
                        }
                    } else {
                        // BCI_OK + zero samples is BrainFlow's normal "nothing
                        // new yet" response, indistinguishable at the status
                        // level from a silently dead BLE link — see
                        // staleTimeoutSec's doc comment. Only this watchdog
                        // catches that case; a real drain error is already
                        // handled above.
                        let staleness = Date().timeIntervalSince(lastSampleAt)
                        if staleness > staleTimeout {
                            BCILog.eeg.error("BrainFlow: no samples for \(staleness, format: .fixed(precision: 1))s (>\(staleTimeout, format: .fixed(precision: 1))s timeout) — treating as a dead link")
                            continuation.finish(throwing: BCIError.streamFailed(
                                reason: "no samples received for \(Int(staleness))s — BLE link likely dead"
                            ))
                            return
                        }
                    }
                    try? await Task.sleep(nanoseconds: UInt64(poll * 1_000_000_000))
                }
                continuation.finish()
            }
            self.lock.withLock { self.pollTask = task }
            continuation.onTermination = { @Sendable [weak self] _ in
                task.cancel()
                Task { await self?.stop() }
            }
        }
    }

    public func stop() async {
        let h: bci_session_handle_t? = lock.withLock {
            let h = self.handle
            self.handle = nil
            self.pollTask?.cancel()
            self.pollTask = nil
            return h
        }
        if let h = h {
            _ = bci_bridge_stop_stream(h)
            bci_bridge_destroy_session(h)
        }
    }

    // MARK: - Helpers

    private func makeParamsJSON() -> String {
        let env = ProcessInfo.processInfo.environment

        // BrainFlow's board_controller requires ALL fields to be present in the JSON
        // (even if empty strings for string fields, 0 for int fields).
        // The JSON parser assigns each field directly, and missing fields become null,
        // which causes a type error when assigning to std::string.

        var serial_port = ""
        var mac_address = ""
        var ip_address = ""
        var ip_address_aux = ""
        var ip_address_anc = ""
        var ip_protocol = 0
        var ip_port = 0
        var ip_port_aux = 0
        var ip_port_anc = 0
        var other_info = ""
        var timeout = 0
        var serial_number = ""
        var file = ""
        var file_aux = ""
        var file_anc = ""
        var master_board = -100 // BoardIds::NO_BOARD

        // serial_port: BLED112 dongle variants. Caller-supplied wins;
        // otherwise honor NEURALCOMPOSE_MUSE_SERIAL for the BLED profiles.
        if let serialPort = self.serialPort {
            serial_port = serialPort
        } else if profile.usesBLEDDongle,
                  let envSerial = env["NEURALCOMPOSE_MUSE_SERIAL"] {
            serial_port = envSerial
        }

        // mac_address: caller wins; otherwise honor NEURALCOMPOSE_MUSE_MAC.
        // BrainFlow uses this to disambiguate when multiple Muse devices are in range.
        if let mac = macAddress {
            mac_address = mac
        } else if let envMac = env["NEURALCOMPOSE_MUSE_MAC"] {
            mac_address = envMac
        }

        // serial_number: BrainFlow's Muse/Muse S/Athena docs list this as an
        // optional selector alongside mac_address. Useful when the MAC isn't
        // known but the printed serial is.
        if let serialNum = env["NEURALCOMPOSE_MUSE_SERIAL_NUMBER"], !serialNum.isEmpty {
            serial_number = serialNum
        }

        // other_info: BrainFlow 5.22+ uses this to pass Athena startup
        // options such as the preset (p1041 / p1042 / p1043) and low_latency=true.
        // We supply a sensible default for Athena; any profile can override
        // via NEURALCOMPOSE_BRAINFLOW_OTHER_INFO.
        if let envOther = env["NEURALCOMPOSE_BRAINFLOW_OTHER_INFO"], !envOther.isEmpty {
            other_info = envOther
        } else if profile == .museSAthena {
            other_info = "preset=p1041;low_latency=true"
        }

        // Construct JSON with all required fields (using default C++ values when not set).
        return """
        {
            "serial_port":"\(escapeJSON(serial_port))",
            "mac_address":"\(escapeJSON(mac_address))",
            "ip_address":"\(escapeJSON(ip_address))",
            "ip_address_aux":"\(escapeJSON(ip_address_aux))",
            "ip_address_anc":"\(escapeJSON(ip_address_anc))",
            "ip_protocol":\(ip_protocol),
            "ip_port":\(ip_port),
            "ip_port_aux":\(ip_port_aux),
            "ip_port_anc":\(ip_port_anc),
            "other_info":"\(escapeJSON(other_info))",
            "timeout":\(timeout),
            "serial_number":"\(escapeJSON(serial_number))",
            "file":"\(escapeJSON(file))",
            "file_aux":"\(escapeJSON(file_aux))",
            "file_anc":"\(escapeJSON(file_anc))",
            "master_board":\(master_board)
        }
        """
    }

    /// Verify `MuseBoardProfile.brainFlowBoardID` against the *compiled*
    /// BrainFlow C++ enum, without opening any hardware session.
    ///
    /// Returns the list of mismatches. Empty list means everything's lined
    /// up. Each mismatch carries both the expected (from MuseBoardProfile)
    /// and the actual (from the bridge's BoardIds getter) so the caller can
    /// log a precise diagnostic.
    ///
    /// In stub-mode builds (no BrainFlow linked) this returns
    /// `.bridgeUnavailable` and skips the comparison — pretending to verify
    /// against nothing would be worse than honestly saying we can't.
    public static func verifyBoardIDsAgainstBridge() -> BoardIDVerification {
        guard bci_bridge_is_available() else {
            return .bridgeUnavailable
        }
        var mismatches: [BoardIDMismatch] = []
        let pairs: [(MuseBoardProfile, () -> Int32)] = [
            (.synthetic,        { bci_bridge_board_id_synthetic()        }),
            (.museTwoNativeBLE, { bci_bridge_board_id_muse_2()           }),
            (.museTwoBLED,      { bci_bridge_board_id_muse_2_bled()      }),
            (.museSNativeBLE,   { bci_bridge_board_id_muse_s()           }),
            (.museSBLED,        { bci_bridge_board_id_muse_s_bled()      }),
            (.museSAthena,      { bci_bridge_board_id_muse_s_athena()    }),
        ]
        for (profile, getter) in pairs {
            let actual = getter()
            guard actual != BCI_BRIDGE_BOARD_ID_UNAVAILABLE else { continue }
            let expected = profile.brainFlowBoardID
            if expected != actual {
                mismatches.append(BoardIDMismatch(profile: profile, expected: expected, actual: actual))
            }
        }
        return mismatches.isEmpty ? .matched : .mismatched(mismatches)
    }

    public enum BoardIDVerification: Sendable {
        case matched
        case mismatched([BoardIDMismatch])
        case bridgeUnavailable
    }

    public struct BoardIDMismatch: Sendable, CustomStringConvertible {
        public let profile: MuseBoardProfile
        public let expected: Int32?
        public let actual: Int32
        public var description: String {
            "\(profile.displayName): MuseBoardProfile=\(expected.map(String.init) ?? "nil"), BrainFlow=\(actual)"
        }
    }

    private func escapeJSON(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
