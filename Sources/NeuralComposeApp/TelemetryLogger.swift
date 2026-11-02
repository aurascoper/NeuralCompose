import Foundation
import BCICore

/// Appends one JSON line per `TelemetryEvent` to a local, never-transmitted
/// file - see `docs/architecture/decision-log/ADR-005-local-interaction-logging.md`
/// for why this is compliant with the project's "no telemetry" principle
/// (that principle is about network egress; this never leaves the machine).
///
/// No `static let shared` - this codebase's composition root is
/// `AppContainer` (`CLAUDE.md`), so instances are constructed and held the
/// same way every other dependency is. Callers are expected to gate on the
/// opt-in `AppViewModel.interactionLoggingEnabled` toggle themselves; this
/// actor writes unconditionally whenever `log(_:)` is called.
///
/// Files rotate daily (`interactions-<yyyy-MM-dd>.jsonl`,
/// `dialectic-turns-<yyyy-MM-dd>.jsonl`, `spoken-trace-<yyyy-MM-dd>.jsonl`,
/// `prosody-trace-<yyyy-MM-dd>.jsonl`), mirroring the dated-session convention
/// `Recordings/night-<date>/` already uses, so no single file grows unbounded
/// across a long-running install.
public actor TelemetryLogger: InteractionLogging, DialecticalTurnLogging, SpokenGenerationTraceLogging, ProsodyTraceLogging {
    private let directory: URL
    private let encoder: JSONEncoder
    private let dayFormatter: DateFormatter

    /// One open handle per stream prefix (`interactions`, `dialectic-turns`,
    /// `spoken-trace`, `prosody-trace`), each rotating daily. Keyed so the
    /// streams never share a file.
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

    /// Per-cycle spoken-loop traces go to their own `spoken-trace-<day>.jsonl`
    /// stream - the input→output diagnostic for broken-vs-starved. Like the
    /// dialectic stream it carries no timestamp, so the day is stamped at write.
    public func log(_ event: SpokenGenerationTraceEvent) async {
        write(event, prefix: "spoken-trace",
              day: dayFormatter.string(from: Date()), id: "cycle-\(event.index)")
    }

    /// Prosody traces go to their own `prosody-trace-<day>.jsonl` stream. This
    /// keeps cadence targets separate from semantic turn telemetry while still
    /// letting offline analysis join streams by index / dialogue-state scalars.
    public func log(_ event: ProsodyTraceEvent) async {
        write(event, prefix: "prosody-trace",
              day: dayFormatter.string(from: Date()), id: "prosody-\(event.index)")
    }

    /// Replaces em-dashes (`\u{2014}`) and en-dashes (`\u{2013}`) with `" - "` so
    /// live telemetry JSONL streams never emit raw typographic dashes to disk.
    public static func sanitizeDashes(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\u{2014}", with: " - ")
            .replacingOccurrences(of: "\u{2013}", with: " - ")
    }

    private func appendLine(_ rawLine: String, to handle: FileHandle) throws {
        let sanitized = Self.sanitizeDashes(rawLine)
        var data = Data(sanitized.utf8)
        data.append(0x0A) // newline
        // `write(contentsOf:)`, not `write(_:)` - the latter raises an
        // uncatchable Objective-C NSException on failure (disk full,
        // permission revoked) instead of a Swift `Error`, which this
        // catch block could not actually intercept.
        try handle.write(contentsOf: data)
    }

    private func write<E: Encodable>(_ event: E, prefix: String, day: String, id: String) {
        do {
            let handle = try fileHandle(prefix: prefix, day: day)
            let encoded = try encoder.encode(event)
            let line = String(decoding: encoded, as: UTF8.self)
            try appendLine(line, to: handle)
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

    // MARK: - Conditional Autobank & Autoforgetting ("when/iff needed")

    /// Summary of an autobank and conditional autoforgetting pass over interaction logs.
    public struct AutobankAndAutoforgetReport: Sendable, Equatable {
        /// Number of expired transient trace files (`spoken-trace-*`, `prosody-trace-*`, `health-*`) removed.
        public let prunedTransientFiles: Int
        /// Total dialectical turns inspected for the target day.
        public let evaluatedTurns: Int
        /// Warrant-bearing turns written to `dialectic-autobank-<day>.jsonl`.
        public let autobankedTurns: Int
        /// Turns filtered out (silent, stutter, backchannel, control/transit, or reflexive collapse).
        public let forgottenTurns: Int
        /// True iff the primary `dialectic-turns-<day>.jsonl` file was compacted in place.
        public let compactedPrimaryLog: Bool

        public init(
            prunedTransientFiles: Int,
            evaluatedTurns: Int,
            autobankedTurns: Int,
            forgottenTurns: Int,
            compactedPrimaryLog: Bool
        ) {
            self.prunedTransientFiles = prunedTransientFiles
            self.evaluatedTurns = evaluatedTurns
            self.autobankedTurns = autobankedTurns
            self.forgottenTurns = forgottenTurns
            self.compactedPrimaryLog = compactedPrimaryLog
        }
    }

    /// Executes session-time conditional autobanking and autoforgetting ("when/iff needed"):
    /// 1. Prunes expired transient trace files (`spoken-trace-<day>.jsonl`,
    ///    `prosody-trace-<day>.jsonl`, `health-<day>.jsonl`) older than `maxTransientAgeDays`
    ///    when `maxTransientAgeDays > 0`.
    /// 2. Evaluates `dialectic-turns-<day>.jsonl` via `DialecticalMemory.shouldAutobankTurn`
    ///    and writes eligible turns to `dialectic-autobank-<day>.jsonl` whenever at least one
    ///    eligible turn exists.
    /// 3. Compacts `dialectic-turns-<day>.jsonl` in place iff `compactPrimaryIfNeeded == true`
    ///    and forgotten/collapsed turns exceed `collapseRatioThreshold` ( preserving a `.bak`
    ///    snapshot before atomic replacement).
    @discardableResult
    public func autobankAndAutoforgetIfNeeded(
        day: String? = nil,
        maxTransientAgeDays: Int = 30,
        maxSelfSimilarity: Float = 0.92,
        compactPrimaryIfNeeded: Bool = false,
        collapseRatioThreshold: Float = 0.25,
        referenceDate: Date = Date()
    ) -> AutobankAndAutoforgetReport {
        let targetDay = day ?? dayFormatter.string(from: referenceDate)
        var prunedFiles = 0

        if maxTransientAgeDays > 0,
           let entries = try? FileManager.default.contentsOfDirectory(atPath: directory.path) {
            let transientPrefixes = ["spoken-trace-", "prosody-trace-", "health-"]
            let cutoff = referenceDate.addingTimeInterval(-Double(maxTransientAgeDays) * 86_400.0)
            for name in entries where name.hasSuffix(".jsonl") {
                guard let matchedPrefix = transientPrefixes.first(where: { name.hasPrefix($0) }) else {
                    continue
                }
                let dayPart = String(name.dropFirst(matchedPrefix.count).dropLast(".jsonl".count))
                guard let fileDate = dayFormatter.date(from: dayPart), fileDate < cutoff else {
                    continue
                }
                let streamKey = String(matchedPrefix.dropLast())
                if let openStream = streams[streamKey], openStream.day == dayPart {
                    openStream.handle.closeFile()
                    streams.removeValue(forKey: streamKey)
                }
                let fileURL = directory.appendingPathComponent(name)
                if (try? FileManager.default.removeItem(at: fileURL)) != nil {
                    prunedFiles += 1
                }
            }
        }

        let primaryURL = directory.appendingPathComponent("dialectic-turns-\(targetDay).jsonl")
        guard FileManager.default.fileExists(atPath: primaryURL.path),
              let content = try? String(contentsOf: primaryURL, encoding: .utf8) else {
            return AutobankAndAutoforgetReport(
                prunedTransientFiles: prunedFiles,
                evaluatedTurns: 0,
                autobankedTurns: 0,
                forgottenTurns: 0,
                compactedPrimaryLog: false
            )
        }

        let decoder = JSONDecoder()
        let rawLines = content.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        var keptLines: [String] = []
        var evaluated = 0
        var forgotten = 0

        for line in rawLines {
            let cleanLine = Self.sanitizeDashes(line)
            guard let data = cleanLine.data(using: .utf8),
                  let event = try? decoder.decode(DialecticalTurnEvent.self, from: data) else {
                continue
            }
            evaluated += 1
            if DialecticalMemory.shouldAutobankTurn(
                heard: event.heard,
                spoken: event.spokenText,
                outcome: event.outcome,
                selfSimilarity: event.selfSimilarity,
                maxSelfSimilarity: maxSelfSimilarity,
                witnessAttempted: event.witnessAttempted ?? true,
                maxCandidatePotential: event.candidates.map(\.potential).max() ?? 0.0
            ) {
                keptLines.append(cleanLine)
            } else {
                forgotten += 1
            }
        }

        if !keptLines.isEmpty {
            let autobankURL = directory.appendingPathComponent("dialectic-autobank-\(targetDay).jsonl")
            let payload = keptLines.joined(separator: "\n") + "\n"
            try? payload.write(to: autobankURL, atomically: true, encoding: .utf8)
        }

        var compacted = false
        if compactPrimaryIfNeeded,
           evaluated > 0,
           forgotten > 0,
           Float(forgotten) / Float(evaluated) >= collapseRatioThreshold {
            if let openStream = streams["dialectic-turns"], openStream.day == targetDay {
                openStream.handle.closeFile()
                streams.removeValue(forKey: "dialectic-turns")
            }
            let backupURL = directory.appendingPathComponent("dialectic-turns-\(targetDay).jsonl.bak")
            if !FileManager.default.fileExists(atPath: backupURL.path) {
                try? FileManager.default.copyItem(at: primaryURL, to: backupURL)
            }
            let compactedPayload = keptLines.isEmpty ? "" : (keptLines.joined(separator: "\n") + "\n")
            if (try? compactedPayload.write(to: primaryURL, atomically: true, encoding: .utf8)) != nil {
                compacted = true
            }
        }

        return AutobankAndAutoforgetReport(
            prunedTransientFiles: prunedFiles,
            evaluatedTurns: evaluated,
            autobankedTurns: keptLines.count,
            forgottenTurns: forgotten,
            compactedPrimaryLog: compacted
        )
    }
}
