import Foundation
import BCICore

/// One trial's metadata as written to imagined_events.csv. Times are Unix
/// epoch seconds, sourced from the protocol actor (`Date().timeIntervalSince1970`
/// inside `ImaginedSpeechProtocol`). They are guaranteed to share a clock with
/// the `wall_time` column in imagined_eeg.csv because both use `Date()`.
struct ImaginedTrialEvent: Sendable {
    let trialIndex: Int
    let target: ImaginedWordClass
    let activeStart: TimeInterval
    var activeEnd: TimeInterval
    let cueStart: TimeInterval
}

/// Track B's data sink. Phase-driven: `markPhase(.active)` opens an active
/// window, `markPhase(.rest)`/`.idle`/`.finished` closes it. While a window is
/// open, every sample handed to `recordSample(_:)` is written. The recorder
/// does NOT compare `EEGSample.timestamp` against protocol timestamps because
/// those clocks do not align in synthetic mode (stream-relative vs. Unix
/// epoch). See [[project-calibration-pipeline-gotchas]] — this is the second
/// time a clock-mismatch silently zeroed out Track B.
///
/// Concurrency contract:
///  * `recordSample(_:)` is called for every EEG sample seen by the
///    supervisor while the session is open. Writes iff window is open.
///  * `markPhase(_:)` is called for each `ImaginedSpeechProtocolState`. It
///    is the single source of truth for "are we capturing right now".
public actor TrackBRecorder {
    /// Where Track B sessions live. Deliberately distinct from Track A's
    /// `Recordings/` so a future `train-intent-classifier.py --all` cannot
    /// accidentally vacuum these up.
    public static let directoryName = "TrackB_Imagined"

    public private(set) var sessionID: String = ""
    public private(set) var activeSampleCount: Int = 0
    public private(set) var droppedSampleCount: Int = 0
    public private(set) var completedTrialCount: Int = 0

    private var eegFileHandle: FileHandle?
    private var eventsFileHandle: FileHandle?
    private var sessionURL: URL?
    private var channelLabels: [String] = []
    private var channelCountResolved: Int?
    private var eegHeaderWritten: Bool = false

    /// One in-flight active window. Presence == "currently capturing". Closing
    /// is done by `markPhase` on any non-active phase transition.
    private struct ActiveWindow {
        let trialIndex: Int
        let target: ImaginedWordClass
        let cueStart: TimeInterval
        let activeStart: TimeInterval     // protocol Unix epoch
        let openedAtWall: TimeInterval    // local Date().timeIntervalSince1970
    }
    private var currentActiveWindow: ActiveWindow?

    /// Latest cue phase we saw — buffered so when the active phase arrives we
    /// know what the upcoming target was. (Cue and active emit as separate
    /// state events with `target` set on both.)
    private var pendingCueTrialIndex: Int?
    private var pendingCueTarget: ImaginedWordClass?
    private var pendingCueStart: TimeInterval?

    private var allEvents: [ImaginedTrialEvent] = []
    private var profile: MuseBoardProfile = .synthetic
    private var sampleRate: Double = 256.0
    private var protocolConfig: ImaginedSpeechProtocol.Config?
    private var protocolSeed: UInt64?

    // Diagnostic running min/max for metadata.json.
    private var firstActiveWallTime: TimeInterval?
    private var lastActiveWallTime: TimeInterval?
    private var firstSampleTimestamp: TimeInterval?
    private var lastSampleTimestamp: TimeInterval?

    public init() {}

    /// Open the session directory + CSV files. Returns the session URL so
    /// callers can show it in the UI ("Saved to …").
    @discardableResult
    public func beginSession(
        root: URL,
        profile: MuseBoardProfile,
        sampleRate: Double,
        protocolConfig: ImaginedSpeechProtocol.Config,
        protocolSeed: UInt64
    ) throws -> URL {
        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withFullDate, .withTime]
        let ts = dateFormatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let profileStr = profileString(profile)
        sessionID = "imagined_\(ts)_\(profileStr)"

        let sessionDir = root.appendingPathComponent(sessionID)
        try FileManager.default.createDirectory(at: sessionDir, withIntermediateDirectories: true)

        self.profile = profile
        self.sampleRate = sampleRate
        self.protocolConfig = protocolConfig
        self.protocolSeed = protocolSeed
        channelLabels = profile.channelLabels   // may be empty for synthetic; resolved on first sample
        channelCountResolved = channelLabels.isEmpty ? nil : channelLabels.count

        let eegURL = sessionDir.appendingPathComponent("imagined_eeg.csv")
        FileManager.default.createFile(atPath: eegURL.path, contents: nil)
        eegFileHandle = try FileHandle(forWritingTo: eegURL)
        eegHeaderWritten = false
        // If we already know the channel layout (profile.channelLabels non-empty)
        // write the header eagerly. Otherwise we defer until the first sample
        // arrives so we don't commit to a 4-ch synthetic layout when the user
        // actually has Muse aux electrodes wired. But we ALWAYS leave a header
        // behind in finishSession() so the file is parseable even on a session
        // that never received an EEG sample.
        if let count = channelCountResolved {
            writeEEGHeader(channelCount: count)
        }

        let eventsHeader = "session_id,trial_index,target,cue_start,active_start,active_end\n"
        let eventsURL = sessionDir.appendingPathComponent("imagined_events.csv")
        FileManager.default.createFile(atPath: eventsURL.path, contents: nil)
        eventsFileHandle = try FileHandle(forWritingTo: eventsURL)
        eventsFileHandle?.write(Data(eventsHeader.utf8))

        sessionURL = sessionDir
        activeSampleCount = 0
        droppedSampleCount = 0
        completedTrialCount = 0
        currentActiveWindow = nil
        allEvents.removeAll(keepingCapacity: true)
        firstActiveWallTime = nil
        lastActiveWallTime = nil
        firstSampleTimestamp = nil
        lastSampleTimestamp = nil
        return sessionDir
    }

    /// Forward every EEG sample here, regardless of phase. The recorder writes
    /// iff a window is currently open; the protocol — not the sample clock —
    /// is the source of truth for "is this sample inside an active phase".
    public func recordSample(_ sample: EEGSample) {
        guard eegFileHandle != nil else { return }
        ensureHeaderWritten(channelCount: sample.channels.count)

        if firstSampleTimestamp == nil { firstSampleTimestamp = sample.timestamp }
        lastSampleTimestamp = sample.timestamp

        guard let window = currentActiveWindow else {
            droppedSampleCount += 1
            return
        }
        let wallNow = Date().timeIntervalSince1970
        writeSampleRow(sample, window: window, wallNow: wallNow)
        if firstActiveWallTime == nil { firstActiveWallTime = wallNow }
        lastActiveWallTime = wallNow
        activeSampleCount += 1
    }

    /// Called for every `ImaginedSpeechProtocolState` from the protocol.
    /// Opens an active window on `.active` and closes it on `.rest`/`.idle`/
    /// `.finished`. `.cue` is buffered so the active window knows its cue
    /// origin timestamp.
    public func markPhase(_ state: ImaginedSpeechProtocolState) {
        switch state.phase {
        case .cue:
            // Only react to the *entry* event of the cue (timeRemaining == phaseDuration).
            // Subsequent 100ms ticks during the cue should not re-buffer.
            if abs(state.timeRemaining - state.phaseDuration) < 0.01,
               let target = state.target {
                pendingCueTrialIndex = state.trialIndex
                pendingCueTarget = target
                pendingCueStart = state.phaseStartTimestamp
            }
        case .active:
            // Only react to the entry event.
            if abs(state.timeRemaining - state.phaseDuration) < 0.01,
               let target = state.target {
                let cueStart = pendingCueStart ?? state.phaseStartTimestamp
                currentActiveWindow = ActiveWindow(
                    trialIndex: state.trialIndex,
                    target: target,
                    cueStart: cueStart,
                    activeStart: state.phaseStartTimestamp,
                    openedAtWall: Date().timeIntervalSince1970
                )
                allEvents.append(ImaginedTrialEvent(
                    trialIndex: state.trialIndex,
                    target: target,
                    activeStart: state.phaseStartTimestamp,
                    activeEnd: state.phaseStartTimestamp,   // backfilled when window closes
                    cueStart: cueStart
                ))
            }
        case .rest, .idle, .finished:
            if let window = currentActiveWindow {
                // Backfill the trailing edge of the last open trial event.
                if let last = allEvents.last,
                   last.trialIndex == window.trialIndex,
                   last.target == window.target {
                    var updated = last
                    updated.activeEnd = state.phaseStartTimestamp
                    allEvents[allEvents.count - 1] = updated
                    writeEventRow(updated)
                    completedTrialCount += 1
                }
                currentActiveWindow = nil
                pendingCueTrialIndex = nil
                pendingCueTarget = nil
                pendingCueStart = nil
            }
        }
    }

    public func finishSession() async {
        // Close any orphan active window — happens if the user clicked Stop
        // mid-trial. Backfill activeEnd to "now" so the partial trial isn't a
        // zero-duration row.
        if let window = currentActiveWindow {
            let now = Date().timeIntervalSince1970
            if let last = allEvents.last,
               last.trialIndex == window.trialIndex {
                var updated = last
                updated.activeEnd = now
                allEvents[allEvents.count - 1] = updated
                writeEventRow(updated)
            }
            currentActiveWindow = nil
        }

        // Last-resort: leave a header even if no sample ever arrived, so the
        // evaluator and any human inspection tool can still parse the file.
        if !eegHeaderWritten, eegFileHandle != nil {
            let count = channelCountResolved ?? max(channelLabels.count, 4)
            writeEEGHeader(channelCount: count)
        }

        eegFileHandle?.closeFile()
        eventsFileHandle?.closeFile()

        if let sessionURL = self.sessionURL {
            var metadata: [String: Any] = [
                "session_id": sessionID,
                "profile": profileString(profile),
                "sample_rate": sampleRate,
                "channel_labels": channelLabels,
                "channel_count": channelCountResolved ?? channelLabels.count,
                "active_sample_count": activeSampleCount,
                "dropped_sample_count": droppedSampleCount,
                "completed_trial_count": completedTrialCount,
                "eeg_header_written": eegHeaderWritten,
                "timestamp": ISO8601DateFormatter().string(from: Date())
            ]
            if let v = firstActiveWallTime { metadata["first_active_wall_time"] = v }
            if let v = lastActiveWallTime  { metadata["last_active_wall_time"]  = v }
            if let v = firstSampleTimestamp { metadata["first_sample_timestamp"] = v }
            if let v = lastSampleTimestamp  { metadata["last_sample_timestamp"]  = v }
            if let cfg = protocolConfig {
                metadata["protocol"] = [
                    "cue_seconds": cfg.cueSeconds,
                    "active_seconds": cfg.activeSeconds,
                    "rest_seconds": cfg.restSeconds,
                    "trials_per_class": cfg.trialsPerClass,
                    "active_classes": cfg.activeClasses.map { $0.rawString },
                    "total_trials": cfg.totalTrials
                ]
            }
            if let seed = protocolSeed {
                metadata["trial_order_seed"] = String(seed)
            }
            if let jsonData = try? JSONSerialization.data(withJSONObject: metadata,
                                                          options: [.prettyPrinted, .sortedKeys]) {
                let metadataURL = sessionURL.appendingPathComponent("metadata.json")
                FileManager.default.createFile(atPath: metadataURL.path, contents: jsonData)
            }
        }

        BCILog.pipeline.notice("TrackBRecorder: session \(self.sessionID) complete — \(self.completedTrialCount) trials, \(self.activeSampleCount) active samples, \(self.droppedSampleCount) dropped → \(self.sessionURL?.path ?? "?")")

        eegFileHandle = nil
        eventsFileHandle = nil
        sessionURL = nil
    }

    // MARK: - Writers

    private func ensureHeaderWritten(channelCount: Int) {
        guard !eegHeaderWritten else { return }
        if channelLabels.isEmpty || channelLabels.count != channelCount {
            channelLabels = (0..<channelCount).map { "ch\($0)" }
        }
        channelCountResolved = channelCount
        writeEEGHeader(channelCount: channelCount)
    }

    private func writeEEGHeader(channelCount: Int) {
        guard let fh = eegFileHandle, !eegHeaderWritten else { return }
        if channelLabels.count != channelCount {
            channelLabels = (0..<channelCount).map { "ch\($0)" }
        }
        channelCountResolved = channelCount
        let header = "wall_time,sample_timestamp,trial_index,target," + channelLabels.joined(separator: ",") + "\n"
        fh.write(Data(header.utf8))
        eegHeaderWritten = true
    }

    private func writeSampleRow(_ sample: EEGSample, window: ActiveWindow, wallNow: TimeInterval) {
        guard let fh = eegFileHandle else { return }
        let chStr = sample.channels.map { String(format: "%.6f", $0) }.joined(separator: ",")
        let row = "\(String(format: "%.9f", wallNow)),\(String(format: "%.9f", sample.timestamp)),\(window.trialIndex),\(window.target.rawString),\(chStr)\n"
        fh.write(Data(row.utf8))
    }

    private func writeEventRow(_ event: ImaginedTrialEvent) {
        guard let fh = eventsFileHandle else { return }
        let row = "\(sessionID),\(event.trialIndex),\(event.target.rawString),\(String(format: "%.6f", event.cueStart)),\(String(format: "%.6f", event.activeStart)),\(String(format: "%.6f", event.activeEnd))\n"
        fh.write(Data(row.utf8))
    }

    private func profileString(_ profile: MuseBoardProfile) -> String {
        switch profile {
        case .synthetic: return "synthetic"
        case .playback:  return "playback"
        default:         return "muse"
        }
    }
}
