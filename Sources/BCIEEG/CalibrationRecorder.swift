import Foundation
import BCICore

struct CalibrationLabelEvent: Sendable {
    let tStart: Double
    var tEnd: Double
    let label: CalibrationLabel
}

/// Bookkeeping for an in-flight sticky press: points at the row inside
/// `allEvents` so `endStickyLabel` can backfill `tEnd` without copying a
/// value-type event around.
struct StickyState: Sendable {
    let label: CalibrationLabel
    let allEventsIndex: Int
}

private extension CalibrationLabel {
    var isSticky: Bool {
        switch self {
        case .rest, .jawClench, .artifact: return true
        case .blink, .doubleBlink, .select: return false
        }
    }
}

/// A discrete transport lifecycle event, recorded alongside the raw
/// EEG/label data so a session can be told apart from one where the
/// live link stayed up the whole time. Distinct from
/// `CalibrationLabelEvent`: that type is a *behavioral* protocol
/// marker (blink, jaw clench, rest) the participant or protocol
/// script produces; this is a *transport diagnostic* the pipeline
/// itself produces, independent of anything the participant did.
public enum TransportEventKind: String, Sendable {
    /// The live stream stopped producing samples and the supervisor
    /// began a retry/backoff attempt.
    case stalled
    /// A retry succeeded — the live stream is producing samples
    /// again after a prior `stalled` event.
    case reconnected
    /// Retries were exhausted and the pipeline fell back to the
    /// synthetic source. Everything recorded after this event for
    /// the remainder of the session is synthetic, not live, data.
    case fellBackToSynthetic
}

struct TransportEvent: Sendable {
    /// Unix epoch wall-clock time, **not** stream-relative like
    /// `EEGSample.timestamp` / `CalibrationLabelEvent.tStart`. A
    /// transport event has no meaningful position on the live
    /// stream's own relative clock — that clock restarts (or stops
    /// altogether) at exactly the moments this event records.
    let t: Double
    let kind: TransportEventKind
    let detail: String
}

public actor CalibrationRecorder {
    public private(set) var sessionID: String = ""
    public private(set) var windowCount: Int = 0
    public private(set) var sampleCount: Int = 0

    private var eegFileHandle: FileHandle?
    private var eventsFileHandle: FileHandle?
    private var labelsFileHandle: FileHandle?
    private var transportEventsFileHandle: FileHandle?
    private var sessionURL: URL?
    private var channelLabels: [String] = []
    private var activeEvents: [StickyState] = []
    private var allEvents: [CalibrationLabelEvent] = []
    private var transportEvents: [TransportEvent] = []
    private var windowingConfig: (seconds: Double, strideSeconds: Double) = (2.0, 1.0)
    private var profile: MuseBoardProfile = .synthetic
    private var sampleRate: Double = 256.0

    public init() {}

    public func beginSession(
        to directory: URL,
        profile: MuseBoardProfile,
        windowingSeconds: Double = 2.0,
        strideSeconds: Double = 1.0,
        sampleRate: Double = 256.0
    ) throws {
        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withFullDate, .withTime]
        let ts = dateFormatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")

        let profileStr = profile == .synthetic ? "synthetic" : "muses"
        sessionID = "calibration_\(ts)_\(profileStr)"

        let sessionDir = directory.appendingPathComponent(sessionID)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)

        self.profile = profile
        self.sampleRate = sampleRate
        self.windowingConfig = (windowingSeconds, strideSeconds)
        channelLabels = profile.channelLabels.isEmpty ? ["ch0","ch1","ch2","ch3"] : profile.channelLabels

        let eegHeader = "t_seconds," + channelLabels.joined(separator: ",") + "\n"
        let eegURL = sessionDir.appendingPathComponent("eeg.csv")
        FileManager.default.createFile(atPath: eegURL.path, contents: nil)
        eegFileHandle = try FileHandle(forWritingTo: eegURL)
        eegFileHandle?.write(Data(eegHeader.utf8))

        let eventsHeader = "session_id,t_start,t_end,label\n"
        let eventsURL = sessionDir.appendingPathComponent("events.csv")
        FileManager.default.createFile(atPath: eventsURL.path, contents: nil)
        eventsFileHandle = try FileHandle(forWritingTo: eventsURL)
        eventsFileHandle?.write(Data(eventsHeader.utf8))

        let labelsHeader = "session_id,window_seq,t_start,t_end,label,profile,sample_rate\n"
        let labelsURL = sessionDir.appendingPathComponent("labels.csv")
        FileManager.default.createFile(atPath: labelsURL.path, contents: nil)
        labelsFileHandle = try FileHandle(forWritingTo: labelsURL)
        labelsFileHandle?.write(Data(labelsHeader.utf8))

        let transportHeader = "session_id,t_wallclock_epoch,event,detail\n"
        let transportURL = sessionDir.appendingPathComponent("transport_events.csv")
        FileManager.default.createFile(atPath: transportURL.path, contents: nil)
        transportEventsFileHandle = try FileHandle(forWritingTo: transportURL)
        transportEventsFileHandle?.write(Data(transportHeader.utf8))

        sessionURL = sessionDir
        windowCount = 0
        sampleCount = 0
        transportEvents = []
    }

    /// Records a transport lifecycle event (stall / reconnect /
    /// fallback-to-synthetic) to `transport_events.csv` and keeps an
    /// in-memory tally for the `transport_degraded` /
    /// `transport_event_count` summary fields `finishSession()` writes
    /// into `metadata.json`. Call from `AppViewModel`'s stream
    /// supervisor whenever it changes retry state — see
    /// `TransportEventKind`'s doc comment for what each case means.
    ///
    /// - Parameter t: Unix epoch wall-clock time (`Date().timeIntervalSince1970`),
    ///   not stream-relative — see `TransportEvent.t`'s doc comment.
    public func recordTransportEvent(_ kind: TransportEventKind, at t: Double, detail: String = "") {
        let event = TransportEvent(t: t, kind: kind, detail: detail)
        transportEvents.append(event)
        guard let fh = transportEventsFileHandle else { return }
        let escapedDetail = detail.replacingOccurrences(of: ",", with: ";")
        let row = "\(sessionID),\(String(format: "%.6f", t)),\(kind.rawValue),\(escapedDetail)\n"
        fh.write(Data(row.utf8))
    }

    public func startStickyLabel(_ label: CalibrationLabel, at t: Double) {
        endStickyLabel(at: t)
        // Store once in allEvents and remember its index so endStickyLabel
        // can backfill tEnd. CalibrationLabelEvent is a struct, so the copy
        // we put in activeEvents is independent of the one in allEvents —
        // mutating activeEvents[idx] doesn't update allEvents at all.
        // (That divergence is the bug that wrote 0-duration sticky events.)
        let event = CalibrationLabelEvent(tStart: t, tEnd: t, label: label)
        allEvents.append(event)
        let allEventsIndex = allEvents.count - 1
        activeEvents.append(StickyState(label: label, allEventsIndex: allEventsIndex))
    }

    public func endStickyLabel(at t: Double) {
        for sticky in activeEvents where sticky.label.isSticky {
            allEvents[sticky.allEventsIndex].tEnd = t
        }
        activeEvents.removeAll { $0.label.isSticky }
    }

    public func addTimedEvent(_ label: CalibrationLabel, at t: Double) {
        let duration: Double
        switch label {
        case .blink:       duration = 2.0
        case .doubleBlink: duration = 3.0
        case .select:      duration = 2.0
        default:           duration = 2.0
        }
        let event = CalibrationLabelEvent(tStart: t, tEnd: t + duration, label: label)
        allEvents.append(event)
        writeEvent(event)
    }

    public func recordSample(_ sample: EEGSample) {
        guard let fh = eegFileHandle else { return }
        let chStr = sample.channels.map { String(format: "%.6f", $0) }.joined(separator: ",")
        let row = "\(String(format: "%.9f", sample.timestamp)),\(chStr)\n"
        fh.write(Data(row.utf8))
        sampleCount += 1
    }

    public func recordWindow(_ window: EEGWindow) {
        guard let fh = labelsFileHandle else { return }
        let tStart = window.endTimestamp - window.durationSeconds
        let tEnd = window.endTimestamp

        let resolvedLabel = resolveLabel(for: tStart, to: tEnd)
        let profileStr = profile == .synthetic ? "synthetic" : "muses"
        let row = "\(sessionID),\(window.sequence),\(String(format: "%.6f", tStart)),\(String(format: "%.6f", tEnd)),\(resolvedLabel),\(profileStr),\(String(format: "%.1f", window.sampleRate))\n"
        fh.write(Data(row.utf8))
        windowCount += 1
    }

    public func finishSession() async {
        // Close any still-active sticky labels at stop time. Without this an
        // orphan sticky (e.g. user clicked the [r] Rest button but never hit
        // [Esc] Clear before Stop) would be written as a zero-duration event
        // and contribute nothing to label resolution.
        let now = Date().timeIntervalSince1970
        endStickyLabel(at: now)

        if let fh = eventsFileHandle {
            for event in allEvents {
                let row = "\(self.sessionID),\(String(format: "%.6f", event.tStart)),\(String(format: "%.6f", event.tEnd)),\(event.label.rawValue)\n"
                fh.write(Data(row.utf8))
            }
        }

        eegFileHandle?.closeFile()
        eventsFileHandle?.closeFile()
        labelsFileHandle?.closeFile()
        transportEventsFileHandle?.closeFile()

        if let sessionURL = self.sessionURL {
            let metadata: [String: Any] = [
                "session_id": self.sessionID,
                "profile": self.profile == .synthetic ? "synthetic" : "muses",
                "transport": self.profile.transportLabel,
                "sample_rate": self.sampleRate,
                "window_seconds": self.windowingConfig.seconds,
                "stride_seconds": self.windowingConfig.strideSeconds,
                "timestamp": ISO8601DateFormatter().string(from: Date()),
                // A non-empty transport event log means the live link
                // stalled, retried, or fell back to synthetic at some
                // point during this session — see transport_events.csv
                // for exactly when and what kind. Surfaced here as a
                // summary so a downstream consumer doesn't have to open
                // that file just to know whether the session was
                // affected at all.
                "transport_degraded": !self.transportEvents.isEmpty,
                "transport_event_count": self.transportEvents.count
            ]
            if let jsonData = try? JSONSerialization.data(withJSONObject: metadata, options: .prettyPrinted) {
                let metadataURL = sessionURL.appendingPathComponent("metadata.json")
                FileManager.default.createFile(atPath: metadataURL.path, contents: jsonData)
            }
        }

        BCILog.pipeline.notice("CalibrationRecorder: session \(self.sessionID) complete — \(self.windowCount) windows, \(self.sampleCount) samples → \(self.sessionURL?.path ?? "?")")

        eegFileHandle = nil
        eventsFileHandle = nil
        labelsFileHandle = nil
        transportEventsFileHandle = nil
    }

    private func writeEvent(_ event: CalibrationLabelEvent) {
        guard let fh = eventsFileHandle else { return }
        let row = "\(sessionID),\(String(format: "%.6f", event.tStart)),\(String(format: "%.6f", event.tEnd)),\(event.label.rawValue)\n"
        fh.write(Data(row.utf8))
    }

    private func resolveLabel(for tStart: Double, to tEnd: Double) -> String {
        let windowDuration = tEnd - tStart
        var maxOverlap: Double = 0
        var resolvedLabel = "none"

        for event in allEvents {
            let overlapStart = max(tStart, event.tStart)
            let overlapEnd = min(tEnd, event.tEnd)
            let overlap = max(0, overlapEnd - overlapStart)

            if overlap > maxOverlap {
                maxOverlap = overlap
                resolvedLabel = event.label.rawValue
            }
        }

        return maxOverlap > 0 ? resolvedLabel : "none"
    }
}
