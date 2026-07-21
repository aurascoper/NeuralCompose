import BCICore
import Foundation

/// Always-on writer for the app watchdog's `HealthSnapshot`.
///
/// - `~/Documents/NeuralCompose/health.json` — the latest snapshot, atomically
///   overwritten each tick, so `cat health.json` always shows current health
///   (this is the file that replaces the unreadable `os_log` during a live run).
/// - `~/Documents/NeuralCompose/InteractionLogs/health-<day>.jsonl` — appended
///   only when the degraded-reason set changes, plus a ~60s heartbeat, so it is a
///   sparse transition log rather than a firehose.
///
/// Diagnostic metadata only (backends / throughput / state — never transcripts),
/// so it is always-on and independent of the interaction-log opt-in (ADR-005).
public actor HealthLogger {
    private let latestURL: URL
    private let logDirectory: URL
    private let dayFormatter: DateFormatter
    private let pretty: JSONEncoder
    private let compact: JSONEncoder
    private var lastDegradedKey: String?
    private var lastHeartbeat: Date?

    public init(baseDirectory: URL = HealthLogger.defaultBaseDirectory()) {
        self.latestURL = baseDirectory.appendingPathComponent("health.json")
        self.logDirectory = baseDirectory.appendingPathComponent("InteractionLogs", isDirectory: true)

        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        df.locale = Locale(identifier: "en_US_POSIX")
        self.dayFormatter = df

        let p = JSONEncoder()
        p.dateEncodingStrategy = .iso8601
        p.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.pretty = p

        let c = JSONEncoder()
        c.dateEncodingStrategy = .iso8601
        self.compact = c
    }

    public static func defaultBaseDirectory() -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("NeuralCompose", isDirectory: true)
    }

    public func write(_ snapshot: HealthSnapshot) {
        // 1. Latest snapshot — atomic overwrite so a reader never sees a torn file.
        if let data = try? pretty.encode(snapshot) {
            try? FileManager.default.createDirectory(
                at: latestURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: latestURL, options: .atomic)
        }

        // 2. Append to the day log only on a degraded-state change or a ~60s heartbeat.
        let key = snapshot.degraded.sorted().joined(separator: ",")
        let now = snapshot.timestamp
        let heartbeatDue = lastHeartbeat.map { now.timeIntervalSince($0) >= 60 } ?? true
        guard key != lastDegradedKey || heartbeatDue else { return }
        lastDegradedKey = key
        lastHeartbeat = now
        appendEvent(snapshot, day: dayFormatter.string(from: now))
    }

    private func appendEvent(_ snapshot: HealthSnapshot, day: String) {
        guard var line = try? compact.encode(snapshot) else { return }
        line.append(0x0A)
        let url = logDirectory.appendingPathComponent("health-\(day).jsonl")
        try? FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)  // catchable (unlike write(_:)) — see TelemetryLogger
        } else {
            try? line.write(to: url, options: .atomic)  // first write of the day: create it
        }
    }
}
