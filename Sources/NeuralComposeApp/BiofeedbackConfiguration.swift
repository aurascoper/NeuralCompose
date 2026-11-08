import Foundation
import BCIBiofeedback

/// Launch-environment configuration for the biofeedback egress (ADR-011,
/// `decision_registry.md` entry 10). Mirrors `PeerBridgeConfiguration`:
/// env-var-only resolution, because Finder/DMG launches do not inherit
/// shell variables and this is a scripted-harness affordance until the
/// mapping UI (issue 5) gives it a settings surface. Absent variables mean
/// the feature is off and `AppContainer.biofeedback` is `nil`.
///
/// Variables:
///
/// - `NEURALCOMPOSE_BIOFEEDBACK_OSC`: `1` (loopback, port 7000), a bare
///   port (`7001`, loopback), or `host:port` (any other host is the LAN
///   tier and is shown as such in the privacy indicator). `0` or empty
///   disables OSC. Malformed values disable OSC rather than guess a host.
/// - `NEURALCOMPOSE_BIOFEEDBACK_MIDI`: `1` creates the CoreMIDI virtual
///   source "NeuralCompose Biofeedback" (in-machine, not network).
/// - `NEURALCOMPOSE_BIOFEEDBACK_RAW_EEG`: `1` re-broadcasts raw `/muse/eeg`
///   over OSC. Ignored without OSC; MIDI cannot carry it.
/// - `NEURALCOMPOSE_BIOFEEDBACK_PER_CHANNEL`: `1` sends four floats per band
///   (Mind Monitor's "separate values for each sensor") instead of one.
/// - `NEURALCOMPOSE_BIOFEEDBACK_MAPPINGS`: path to a JSON array of
///   `BiofeedbackMapping`. Optional; without it only the Mind Monitor
///   mirror runs.
public struct BiofeedbackConfiguration: Sendable, Equatable {

    public struct OSC: Sendable, Equatable {
        public let host: String
        public let port: UInt16

        public static let defaultHost = "127.0.0.1"
        public static let defaultPort: UInt16 = 7000

        public init(host: String = defaultHost, port: UInt16 = defaultPort) {
            self.host = host
            self.port = port
        }

        public var isLoopback: Bool {
            host == "127.0.0.1" || host == "localhost" || host == "::1"
        }

        public var endpoint: String { "\(host):\(port)" }
    }

    /// Which egress tier is active, for the privacy indicator.
    public enum Tier: Sendable, Equatable {
        case off
        /// CoreMIDI only: nothing leaves the machine.
        case midiOnly
        /// OSC to 127.0.0.1: UDP, but the datagrams never leave the machine.
        case loopback
        /// OSC to another host on the user's network.
        case lan
    }

    public let osc: OSC?
    public let midi: Bool
    public let includeRawEEG: Bool
    public let perChannel: Bool
    public let mappingsPath: String?

    public static let disabled = BiofeedbackConfiguration(osc: nil, midi: false, includeRawEEG: false, perChannel: false, mappingsPath: nil)

    public init(osc: OSC?, midi: Bool, includeRawEEG: Bool, perChannel: Bool, mappingsPath: String?) {
        self.osc = osc
        self.midi = midi
        // Raw EEG rides on OSC only; without OSC the flag has nothing to
        // carry it and is dropped here so no later check can be fooled.
        self.includeRawEEG = includeRawEEG && osc != nil
        self.perChannel = perChannel
        self.mappingsPath = mappingsPath
    }

    public var isEnabled: Bool { osc != nil || midi }

    public var tier: Tier {
        if let osc {
            return osc.isLoopback ? .loopback : .lan
        }
        return midi ? .midiOnly : .off
    }

    /// Short badge text for the top bar.
    public var badgeLabel: String {
        switch tier {
        case .off: return ""
        case .midiOnly: return "Biofeedback: MIDI"
        case .loopback: return midi ? "Biofeedback: MIDI + OSC loopback" : "Biofeedback: OSC loopback"
        case .lan: return midi ? "Biofeedback: MIDI + OSC LAN" : "Biofeedback: OSC LAN"
        }
    }

    /// One line per transport for the expanded Network row.
    public var statusLines: [String] {
        var lines: [String] = []
        if midi {
            lines.append("Biofeedback out: MIDI virtual source (in-machine)")
        }
        if let osc {
            lines.append("Biofeedback out: OSC \(osc.endpoint) (\(osc.isLoopback ? "loopback" : "LAN"))")
        }
        if includeRawEEG {
            lines.append("Raw /muse/eeg re-broadcast ON")
        }
        return lines
    }

    /// Resolve from the launch environment. Never throws; a malformed OSC
    /// value disables OSC and the caller logs the raw string.
    public static func resolve(environment: [String: String]) -> BiofeedbackConfiguration {
        let osc = parseOSC(environment["NEURALCOMPOSE_BIOFEEDBACK_OSC"])
        let midi = isOn(environment["NEURALCOMPOSE_BIOFEEDBACK_MIDI"])
        let raw = isOn(environment["NEURALCOMPOSE_BIOFEEDBACK_RAW_EEG"])
        let perChannel = isOn(environment["NEURALCOMPOSE_BIOFEEDBACK_PER_CHANNEL"])
        let mappings = environment["NEURALCOMPOSE_BIOFEEDBACK_MAPPINGS"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return BiofeedbackConfiguration(
            osc: osc,
            midi: midi,
            includeRawEEG: raw,
            perChannel: perChannel,
            mappingsPath: (mappings?.isEmpty ?? true) ? nil : mappings
        )
    }

    /// `1`, `true`, `loopback` → loopback:7000; a bare port → loopback:port;
    /// `host:port` → that host; anything else → nil.
    static func parseOSC(_ raw: String?) -> OSC? {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        switch value.lowercased() {
        case "0", "false", "off", "no":
            return nil
        case "1", "true", "on", "yes", "loopback", "localhost":
            return OSC()
        default:
            break
        }
        if let port = UInt16(value), port > 0 {
            return OSC(port: port)
        }
        // host:port, with IPv6 literals in brackets: [::1]:7000
        guard let colon = value.lastIndex(of: ":") else { return nil }
        var host = String(value[..<colon])
        let portText = String(value[value.index(after: colon)...])
        guard let port = UInt16(portText), port > 0, !host.isEmpty else { return nil }
        if host.hasPrefix("["), host.hasSuffix("]") {
            host = String(host.dropFirst().dropLast())
        }
        return OSC(host: host, port: port)
    }

    static func isOn(_ raw: String?) -> Bool {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else { return false }
        return ["1", "true", "on", "yes"].contains(value)
    }

    /// Load a mapping set from a JSON file (`[BiofeedbackMapping]`).
    public static func loadMappings(at path: String) throws -> [BiofeedbackMapping] {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode([BiofeedbackMapping].self, from: data)
    }
}
