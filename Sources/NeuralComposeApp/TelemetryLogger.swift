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
public actor TelemetryLogger: InteractionLogging {
    private let directory: URL
    private let encoder: JSONEncoder
    private let dayFormatter: DateFormatter

    private var openDay: String?
    private var fileHandle: FileHandle?

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
        let day = dayFormatter.string(from: event.timestamp)
        do {
            let handle = try fileHandle(for: day)
            var data = try encoder.encode(event)
            data.append(0x0A) // newline
            handle.write(data)
        } catch {
            BCILog.telemetry.error("TelemetryLogger: failed to write event \(event.eventId, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Returns the currently-open handle if `day` matches, otherwise closes
    /// any prior handle and opens (creating if needed) `day`'s file.
    private func fileHandle(for day: String) throws -> FileHandle {
        if let fileHandle, openDay == day {
            return fileHandle
        }
        fileHandle?.closeFile()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("interactions-\(day).jsonl")
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: fileURL)
        handle.seekToEndOfFile()
        self.fileHandle = handle
        self.openDay = day
        return handle
    }
}
