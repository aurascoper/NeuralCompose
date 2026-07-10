import Foundation
import BCICore

/// How to derive per-sample timestamps during playback.
///
/// A live BLE recording is an observation of a noisy clock: inter-sample
/// gaps jitter with radio conditions, scheduling, etc. Playback has two
/// different jobs depending on why you're replaying:
///
///  - Debugging acquisition behavior wants the *real*, jittery timing.
///  - Regression testing wants a deterministic, reproducible timeline so the
///    exact same windows/features/classifications come out on every run.
///
/// `.raw` serves the first job; `.normalized` serves the second by
/// resampling onto an exact uniform grid via linear interpolation.
public enum PlaybackTiming: Sendable, Equatable {
    /// Replay using the recorded timestamps and values exactly as logged.
    case raw
    /// Resample onto a uniform `sampleRate` Hz timeline (interpolating
    /// channel values linearly between the two nearest recorded samples)
    /// before replay. Two playbacks of the same file with the same target
    /// rate always produce byte-identical sample sequences, independent of
    /// whatever jitter was present in the original acquisition.
    case normalized(sampleRate: Double)
}

/// How fast to emit samples on the returned stream.
public enum PlaybackPacing: Sendable, Equatable {
    /// Sleep between samples to approximate the recording's real cadence,
    /// so live consumers (the plotter, health badges) see a realistic feed.
    case realtime
    /// Emit every sample as fast as possible with no sleeping. For tests
    /// and CI: a several-minute recording processes in well under a second.
    case instant
}

/// CSV-on-disk playback. CSV format:
///
///     t_seconds,ch0,ch1,ch2,ch3
///     0.0,1.234,-2.345,0.567,...
///     0.00390625,...
///
/// The header is required. The first column is wall-clock-style time in
/// seconds; subsequent columns are float EEG samples.
///
/// `timing` controls whether playback replays the recorded timestamps
/// as-is or resamples onto a deterministic uniform grid first (see
/// `PlaybackTiming`); `pacing` controls whether the returned stream sleeps
/// between samples or emits instantly (see `PlaybackPacing`).
public final class PlaybackEEGStream: EEGStreaming, @unchecked Sendable {

    public let profile: MuseBoardProfile = .playback
    public private(set) var effectiveSampleRate: Double = 256.0
    public private(set) var channelCount: Int = 0

    private let url: URL
    private let timing: PlaybackTiming
    private let pacing: PlaybackPacing
    private let lock = NSLock()
    private var task: Task<Void, Never>?

    public init(path: String, timing: PlaybackTiming = .raw, pacing: PlaybackPacing = .realtime) {
        self.url = URL(fileURLWithPath: path)
        self.timing = timing
        self.pacing = pacing
    }

    public func start() async throws -> AsyncThrowingStream<EEGSample, any Error> {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw BCIError.playbackFileNotFound(path: url.path)
        }
        let contents: String
        do {
            contents = try String(contentsOf: url, encoding: .utf8)
        } catch {
            throw BCIError.playbackFileMalformed(path: url.path, reason: error.localizedDescription)
        }
        let lines = contents.split(separator: "\n", omittingEmptySubsequences: true)
        guard lines.count >= 2 else {
            throw BCIError.playbackFileMalformed(path: url.path, reason: "fewer than 2 rows")
        }
        let header = lines[0].split(separator: ",", omittingEmptySubsequences: false)
        guard header.count >= 2, header[0].trimmingCharacters(in: .whitespaces) == "t_seconds" else {
            throw BCIError.playbackFileMalformed(
                path: url.path,
                reason: "header must begin with 't_seconds,...'"
            )
        }
        channelCount = header.count - 1

        // Parse all rows up front. Recordings are bounded (~minutes) so this
        // is fine; if you want to stream a multi-hour CSV, swap this for a
        // line-by-line reader.
        var rows: [(t: TimeInterval, ch: [Float])] = []
        rows.reserveCapacity(lines.count - 1)
        for raw in lines.dropFirst() {
            let cols = raw.split(separator: ",", omittingEmptySubsequences: false)
            guard cols.count == header.count else {
                throw BCIError.playbackFileMalformed(
                    path: url.path,
                    reason: "row has \(cols.count) cols, expected \(header.count)"
                )
            }
            guard let t = Double(cols[0].trimmingCharacters(in: .whitespaces)) else {
                throw BCIError.playbackFileMalformed(
                    path: url.path,
                    reason: "non-numeric timestamp"
                )
            }
            var chans: [Float] = []
            chans.reserveCapacity(channelCount)
            for i in 1..<cols.count {
                let s = cols[i].trimmingCharacters(in: .whitespaces)
                guard let v = Float(s) else {
                    throw BCIError.playbackFileMalformed(
                        path: url.path,
                        reason: "non-numeric value '\(s)'"
                    )
                }
                chans.append(v)
            }
            rows.append((t, chans))
        }

        // Infer the recorded rate from the full span (average dt), not just
        // the first two rows — a single jittery gap at the start shouldn't
        // skew the estimate for the whole recording.
        if rows.count >= 2 {
            let dt = (rows[rows.count - 1].t - rows[0].t) / Double(rows.count - 1)
            if dt > 0 { effectiveSampleRate = 1.0 / dt }
        }

        let finalRows: [(t: TimeInterval, ch: [Float])]
        switch timing {
        case .raw:
            finalRows = rows
        case .normalized(let targetRate):
            finalRows = Self.resample(rows, to: targetRate)
            effectiveSampleRate = targetRate
        }

        let rowsCopy = finalRows
        let sr = effectiveSampleRate
        let pacingMode = pacing
        return AsyncThrowingStream<EEGSample, any Error> { continuation in
            let task = Task.detached(priority: .userInitiated) {
                switch pacingMode {
                case .instant:
                    for row in rowsCopy {
                        if Task.isCancelled { break }
                        continuation.yield(EEGSample(timestamp: row.t, channels: row.ch))
                    }
                case .realtime:
                    let periodNanos = UInt64(1_000_000_000.0 / sr)
                    let startNanos = DispatchTime.now().uptimeNanoseconds
                    for (i, row) in rowsCopy.enumerated() {
                        if Task.isCancelled { break }
                        continuation.yield(EEGSample(timestamp: row.t, channels: row.ch))
                        let target = startNanos &+ UInt64(i + 1) &* periodNanos
                        let now = DispatchTime.now().uptimeNanoseconds
                        if target > now {
                            try? await Task.sleep(nanoseconds: target &- now)
                        }
                    }
                }
                continuation.finish()
            }
            self.lock.withLock { self.task = task }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    public func stop() async {
        lock.withLock { task?.cancel(); task = nil }
    }

    /// Resample `rows` onto a uniform `targetRate` Hz grid spanning
    /// `[rows.first.t, rows.last.t]`, linearly interpolating channel values
    /// between the two nearest recorded samples. Both `rows` and the output
    /// grid are monotonically increasing in time, so this is a single
    /// forward pass (O(rows.count + output.count)), not O(n²).
    static func resample(
        _ rows: [(t: TimeInterval, ch: [Float])],
        to targetRate: Double
    ) -> [(t: TimeInterval, ch: [Float])] {
        guard rows.count >= 2, targetRate > 0 else { return rows }
        let t0 = rows[0].t
        let duration = rows[rows.count - 1].t - t0
        guard duration > 0 else { return rows }
        let channelCount = rows[0].ch.count
        let dt = 1.0 / targetRate
        let sampleCount = Int((duration / dt).rounded(.down)) + 1

        var out: [(t: TimeInterval, ch: [Float])] = []
        out.reserveCapacity(sampleCount)

        // Invariant going into each iteration: rows[lo].t <= target, and
        // rows[lo+1].t <= target implies lo should advance further (below).
        var lo = 0
        for i in 0..<sampleCount {
            let target = t0 + Double(i) * dt
            while lo + 1 < rows.count - 1 && rows[lo + 1].t <= target {
                lo += 1
            }
            let a = rows[lo]
            let b = rows[min(lo + 1, rows.count - 1)]
            let span = b.t - a.t
            let frac: Float = span > 0 ? Float((target - a.t) / span) : 0
            var interpolated = [Float](repeating: 0, count: channelCount)
            for c in 0..<channelCount {
                let av = a.ch[c]
                let bv = c < b.ch.count ? b.ch[c] : av
                interpolated[c] = av + (bv - av) * frac
            }
            out.append((t: target, ch: interpolated))
        }
        return out
    }
}
