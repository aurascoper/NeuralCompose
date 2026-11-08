#if canImport(Network)
import Foundation
import Network
import os
import BCIEEG

/// Sends `.osc` outputs as UDP datagrams to one host and port. The
/// biofeedback egress's only network transport; see ADR-011 for why it
/// exists next to a codebase whose first invariant is "no network at
/// runtime", and for the three tiers (loopback, LAN, never beyond).
///
/// Defaults to `127.0.0.1:7000`: the same machine, and the port the Muse
/// Port Max for Live device listens on by default. Any other host is a
/// user's explicit choice and the app surfaces it in the privacy
/// indicator, the same way `MindMonitorOSCStream` surfaces its inbound
/// bind.
///
/// Framing follows Mind Monitor: every tick's messages go out in one OSC
/// bundle with the immediate timetag (`bundle == true`). Set `bundle` to
/// false for a consumer that cannot unwrap bundles; each message is then
/// its own datagram.
///
/// Actor-isolated so sends are serialised; `NWConnection` itself calls
/// back on its own queue and those callbacks touch no actor state.
public actor OSCUDPSender: BiofeedbackSink {

    public let host: String
    public let port: UInt16
    public let bundle: Bool

    private var connection: NWConnection?
    private let logger = Logger(subsystem: "com.neuralcompose.biofeedback", category: "osc-out")

    public init(host: String = "127.0.0.1", port: UInt16 = 7000, bundle: Bool = true) {
        self.host = host
        self.port = port
        self.bundle = bundle
    }

    /// True when the destination is the local machine.
    public nonisolated var isLoopback: Bool {
        host == "127.0.0.1" || host == "localhost" || host == "::1"
    }

    /// Open the connection. Idempotent. Logs the destination at `.notice`
    /// so a session log always records where features were sent.
    public func start() {
        guard connection == nil, let nwPort = NWEndpoint.Port(rawValue: port) else { return }
        let conn = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .udp)
        let logger = self.logger
        let destination = "\(host):\(port)"
        conn.stateUpdateHandler = { state in
            switch state {
            case .ready:
                logger.notice("OSC egress ready -> \(destination, privacy: .public)")
            case .failed(let error):
                logger.error("OSC egress failed -> \(destination, privacy: .public): \(error.localizedDescription, privacy: .public)")
            case .waiting(let error):
                logger.notice("OSC egress waiting -> \(destination, privacy: .public): \(error.localizedDescription, privacy: .public)")
            default:
                break
            }
        }
        conn.start(queue: DispatchQueue(label: "com.neuralcompose.biofeedback.osc-out"))
        connection = conn
        logger.notice("OSC egress started -> \(destination, privacy: .public) (derived features only; see ADR-011)")
    }

    public func stop() {
        connection?.cancel()
        connection = nil
    }

    public func emit(_ outputs: [BiofeedbackOutput]) async {
        guard let connection else { return }
        let messages = outputs.compactMap(\.oscMessage)
        guard !messages.isEmpty else { return }
        if bundle {
            send(OSCEncoder.encodeBundle(messages), over: connection)
        } else {
            for message in messages {
                send(OSCEncoder.encode(message), over: connection)
            }
        }
    }

    private func send(_ data: Data, over connection: NWConnection) {
        let logger = self.logger
        connection.send(content: data, completion: .contentProcessed { error in
            if let error {
                logger.error("OSC egress send error: \(error.localizedDescription, privacy: .public)")
            }
        })
    }
}
#endif
