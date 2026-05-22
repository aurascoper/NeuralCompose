import Foundation
import BCICore

/// CSV-on-disk playback at the original sample rate. CSV format:
///
///     t_seconds,ch0,ch1,ch2,ch3
///     0.0,1.234,-2.345,0.567,...
///     0.00390625,...
///
/// The header is required. The first column is wall-clock-style time in
/// seconds; subsequent columns are float EEG samples. Sample rate is inferred
/// from the first two rows.
public final class PlaybackEEGStream: EEGStreaming, @unchecked Sendable {

    public let profile: MuseBoardProfile = .playback
    public private(set) var effectiveSampleRate: Double = 256.0
    public private(set) var channelCount: Int = 0

    private let url: URL
    private let lock = NSLock()
    private var task: Task<Void, Never>?

    public init(path: String) {
        self.url = URL(fileURLWithPath: path)
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

        if rows.count >= 2 {
            let dt = rows[1].t - rows[0].t
            if dt > 0 { effectiveSampleRate = 1.0 / dt }
        }

        let rowsCopy = rows
        let sr = effectiveSampleRate
        return AsyncThrowingStream<EEGSample, any Error> { continuation in
            let task = Task.detached(priority: .userInitiated) {
                let periodNanos = UInt64(1_000_000_000.0 / sr)
                let startNanos = DispatchTime.now().uptimeNanoseconds
                for (i, row) in rowsCopy.enumerated() {
                    if Task.isCancelled { break }
                    let sample = EEGSample(timestamp: row.t, channels: row.ch)
                    continuation.yield(sample)
                    let target = startNanos &+ UInt64(i + 1) &* periodNanos
                    let now = DispatchTime.now().uptimeNanoseconds
                    if target > now {
                        try? await Task.sleep(nanoseconds: target &- now)
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
}
