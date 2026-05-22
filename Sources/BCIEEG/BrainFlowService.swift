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
    private let serialPort: String?
    private let macAddress: String?

    private let lock = NSLock()
    private var handle: bci_session_handle_t?
    private var pollTask: Task<Void, Never>?

    public init(
        profile: MuseBoardProfile,
        pollIntervalSec: Double = 0.05,
        serialPort: String? = nil,
        macAddress: String? = nil
    ) {
        self.profile = profile
        self.pollIntervalSec = pollIntervalSec
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
        // Build a minimal JSON for BrainFlowInputParams. The bridge's parser
        // only knows about a handful of keys; this is the right surface for
        // Muse over BLE / USB-BT.
        let paramsJSON = makeParamsJSON()
        var newHandle: bci_session_handle_t?
        let status = bci_bridge_create_session(boardID, paramsJSON, &newHandle)
        guard status == BCI_OK, let h = newHandle else {
            throw BCIError.streamConnectFailed(profile: profile, underlying: "status \(status)")
        }
        // Refresh metadata from the device.
        let bridgeCh  = bci_bridge_eeg_channel_count(h)
        let bridgeSR  = bci_bridge_sample_rate(h)
        if bridgeCh > 0 { self.channelCount = Int(bridgeCh) }
        if bridgeSR > 0 { self.effectiveSampleRate = bridgeSR }

        let startStatus = bci_bridge_start_stream(h, 30)
        guard startStatus == BCI_OK else {
            bci_bridge_destroy_session(h)
            throw BCIError.streamConnectFailed(profile: profile, underlying: "start_stream \(startStatus)")
        }
        self.lock.withLock { self.handle = h }

        let cc = channelCount
        let poll = pollIntervalSec
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
                        for i in 0..<Int(got) {
                            var ch: [Float] = []
                            ch.reserveCapacity(cc)
                            for c in 0..<cc {
                                ch.append(samplesBuf[i * cc + c])
                            }
                            continuation.yield(EEGSample(timestamp: tsBuf[i], channels: ch))
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
        var pairs: [String] = []

        // serial_port: BLED112 dongle variants. Caller-supplied wins;
        // otherwise honor NEURALCOMPOSE_MUSE_SERIAL for the BLED profiles.
        if let serialPort = serialPort {
            pairs.append("\"serial_port\":\"\(escapeJSON(serialPort))\"")
        } else if profile.usesBLEDDongle,
                  let envSerial = env["NEURALCOMPOSE_MUSE_SERIAL"] {
            pairs.append("\"serial_port\":\"\(escapeJSON(envSerial))\"")
        }

        // mac_address: caller wins; otherwise honor NEURALCOMPOSE_MUSE_MAC.
        // BrainFlow uses this to disambiguate when multiple Muse devices are
        // in range.
        if let mac = macAddress {
            pairs.append("\"mac_address\":\"\(escapeJSON(mac))\"")
        } else if let envMac = env["NEURALCOMPOSE_MUSE_MAC"] {
            pairs.append("\"mac_address\":\"\(escapeJSON(envMac))\"")
        }

        // serial_number: BrainFlow's Muse/Muse S/Athena docs list this as an
        // optional selector alongside mac_address. Useful when the MAC isn't
        // known but the printed serial is.
        if let serialNumber = env["NEURALCOMPOSE_MUSE_SERIAL_NUMBER"], !serialNumber.isEmpty {
            pairs.append("\"serial_number\":\"\(escapeJSON(serialNumber))\"")
        }

        // other_info: BrainFlow 5.22+ uses this to pass Athena startup
        // options such as the preset (p1041 / p1042 / p1043) and
        // low_latency=true. We supply a sensible default for Athena; any
        // profile can override via NEURALCOMPOSE_BRAINFLOW_OTHER_INFO.
        if let envOther = env["NEURALCOMPOSE_BRAINFLOW_OTHER_INFO"], !envOther.isEmpty {
            pairs.append("\"other_info\":\"\(escapeJSON(envOther))\"")
        } else if profile == .museSAthena {
            pairs.append("\"other_info\":\"preset=p1041;low_latency=true\"")
        }
        return "{\(pairs.joined(separator: ","))}"
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
