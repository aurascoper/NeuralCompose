import Foundation
import BCICore

/// Appends one JSON line per `TelemetryEvent` to a local, never-transmitted
/// file — see `docs/architecture/decision-log/ADR-005-local-interaction-logging.md`
/// for why this is compliant with the project's "no telemetry" principle
/// (that principle is about network egress; this never leaves the machine).
///
/// No `static let shared` — this codebase's composition root is
/// `AppContainer` (`CLAUDE.md`), so instances are constructed and held the
/// same way every other dependency is. Callers are expected to gate on the
/// opt-in `AppViewModel.interactionLoggingEnabled` toggle themselves; this
/// actor writes unconditionally whenever `log(_:)` is called.
///
/// Files rotate daily (`interactions-<yyyy-MM-dd>.jsonl`), mirroring the
/// dated-session convention `Recordings/night-<date>/` already uses, so no
/// single file grows unbounded across a long-running install.
public actor TelemetryLogger: InteractionLogging, DialecticalTurnLogging {
    private let directory: URL
    private let encoder: JSONEncoder
    private let dayFormatter: DateFormatter

    /// One open handle per stream prefix (`interactions`, `dialectic-turns`),
    /// each rotating daily. Keyed so the two streams never share a file.
    private var streams: [String: (day: String, handle: FileHandle)] = [:]

    public init(directory: URL) {
        self.directory = directory
        self.encoder = JSONEncoder()
        self.encoder.dateEncodingStrategy = .iso8601
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone.current
        self.dayFormatter = formatter
    }

    /// `~/Documents/NeuralCompose/InteractionLogs`, matching the
    /// `~/Documents/NeuralCompose/Recordings` convention `CalibrationRecorder`
    /// already uses.
    public static func defaultDirectory() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NeuralCompose")
            .appendingPathComponent("InteractionLogs")
    }

    public func log(_ event: TelemetryEvent) async {
        write(event, prefix: "interactions",
              day: dayFormatter.string(from: event.timestamp), id: event.eventId.uuidString)
    }

    /// Dialectic-turn records go to their own `dialectic-turns-<day>.jsonl`
    /// stream, keeping the schema parallel to (never mixed with) word-commit
    /// telemetry. `DialecticalTurnEvent` carries no timestamp, so the day is
    /// stamped at write time.
    public func log(_ event: DialecticalTurnEvent) async {
        write(event, prefix: "dialectic-turns",
              day: dayFormatter.string(from: Date()), id: "turn-\(event.index)")
    }

    private func write<E: Encodable>(_ event: E, prefix: String, day: String, id: String) {
        do {
            let handle = try fileHandle(prefix: prefix, day: day)
            var data = try encoder.encode(event)
            data.append(0x0A) // newline
            // `write(contentsOf:)`, not `write(_:)` — the latter raises an
            // uncatchable Objective-C NSException on failure (disk full,
            // permission revoked) instead of a Swift `Error`, which this
            // catch block could not actually intercept.
            try handle.write(contentsOf: data)
        } catch {
            BCILog.telemetry.error("TelemetryLogger: failed to write \(prefix, privacy: .public) event \(id, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Returns the open handle for `prefix` if its day matches, otherwise closes
    /// any prior handle for that stream and opens (creating if needed) the file.
    private func fileHandle(prefix: String, day: String) throws -> FileHandle {
        if let existing = streams[prefix], existing.day == day {
            return existing.handle
        }
        streams[prefix]?.handle.closeFile()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("\(prefix)-\(day).jsonl")
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: fileURL)
        handle.seekToEndOfFile()
        streams[prefix] = (day, handle)
        return handle
    }
}
