import XCTest
@testable import BCICore
@testable import BCIEEG

final class PlaybackEEGStreamTests: XCTestCase {

    /// Write a small jittery CSV: nominally 256 Hz but with a deliberately
    /// irregular gap in the middle, like a real BLE recording.
    private func writeJitteryFixture() throws -> URL {
        var lines = ["t_seconds,ch0,ch1"]
        var t: Double = 0
        for i in 0..<200 {
            // Ramp values so interpolation correctness is checkable.
            lines.append("\(t),\(Double(i)),\(Double(i) * 2)")
            // Normally ~1/256s, but widen the gap once to simulate jitter.
            t += (i == 100) ? (1.0 / 256.0) * 3.0 : (1.0 / 256.0)
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("playback-fixture-\(UUID().uuidString).csv")
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func drain(_ stream: AsyncThrowingStream<EEGSample, any Error>) async throws -> [EEGSample] {
        var out: [EEGSample] = []
        for try await sample in stream { out.append(sample) }
        return out
    }

    // MARK: - Raw timing preserves recorded data exactly

    func testRawTimingPreservesOriginalTimestampsAndValues() async throws {
        let url = try writeJitteryFixture()
        defer { try? FileManager.default.removeItem(at: url) }

        let stream = PlaybackEEGStream(path: url.path, timing: .raw, pacing: .instant)
        let samples = try await drain(stream.start())

        XCTAssertEqual(samples.count, 200)
        // Spot-check: value at index 100 should be exactly 100 (ramp, no
        // interpolation applied in raw mode).
        XCTAssertEqual(samples[100].channels[0], 100.0)
        XCTAssertEqual(samples[100].channels[1], 200.0)
        // The jittery gap at i=100 should survive untouched.
        let gap = samples[101].timestamp - samples[100].timestamp
        XCTAssertEqual(gap, (1.0 / 256.0) * 3.0, accuracy: 1e-9)
    }

    // MARK: - Normalized timing produces an exact uniform grid

    func testNormalizedTimingProducesUniformTimestamps() async throws {
        let url = try writeJitteryFixture()
        defer { try? FileManager.default.removeItem(at: url) }

        let stream = PlaybackEEGStream(path: url.path, timing: .normalized(sampleRate: 256.0), pacing: .instant)
        let samples = try await drain(stream.start())

        XCTAssertGreaterThan(samples.count, 2)
        let dt = 1.0 / 256.0
        for i in 1..<samples.count {
            let gap = samples[i].timestamp - samples[i - 1].timestamp
            XCTAssertEqual(gap, dt, accuracy: 1e-9, "sample \(i) gap should be exactly 1/256s regardless of source jitter")
        }
    }

    func testNormalizedTimingInterpolatesValuesCorrectly() async throws {
        // A simple two-row fixture with a known midpoint makes interpolation
        // arithmetic easy to check by hand.
        let lines = [
            "t_seconds,ch0",
            "0.0,0.0",
            "1.0,10.0",
        ]
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("playback-interp-\(UUID().uuidString).csv")
        try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        // Resample onto a 4 Hz grid over the 1-second span: t = 0, 0.25, 0.5, 0.75, 1.0
        let stream = PlaybackEEGStream(path: url.path, timing: .normalized(sampleRate: 4.0), pacing: .instant)
        let samples = try await drain(stream.start())

        XCTAssertEqual(samples.count, 5)
        let expected: [Float] = [0.0, 2.5, 5.0, 7.5, 10.0]
        for (i, sample) in samples.enumerated() {
            XCTAssertEqual(sample.channels[0], expected[i], accuracy: 1e-4, "sample \(i)")
        }
    }

    // MARK: - Determinism: the core guarantee normalized playback exists for

    func testNormalizedPlaybackIsFullyDeterministicAcrossRuns() async throws {
        let url = try writeJitteryFixture()
        defer { try? FileManager.default.removeItem(at: url) }

        let streamA = PlaybackEEGStream(path: url.path, timing: .normalized(sampleRate: 256.0), pacing: .instant)
        let streamB = PlaybackEEGStream(path: url.path, timing: .normalized(sampleRate: 256.0), pacing: .instant)

        let samplesA = try await drain(streamA.start())
        let samplesB = try await drain(streamB.start())

        XCTAssertEqual(samplesA.count, samplesB.count)
        for (a, b) in zip(samplesA, samplesB) {
            XCTAssertEqual(a.timestamp, b.timestamp)
            XCTAssertEqual(a.channels, b.channels)
        }
    }

    // MARK: - Pacing

    func testInstantPacingDoesNotWaitRealTime() async throws {
        let url = try writeJitteryFixture()
        defer { try? FileManager.default.removeItem(at: url) }

        // At real-time 256 Hz pacing, 200 samples would take ~0.78s. Instant
        // pacing should finish in a tiny fraction of that.
        let stream = PlaybackEEGStream(path: url.path, timing: .raw, pacing: .instant)
        let start = DispatchTime.now()
        _ = try await drain(stream.start())
        let elapsedSeconds = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1e9

        XCTAssertLessThan(elapsedSeconds, 0.2, "instant pacing should not sleep between samples")
    }

    // MARK: - Rate inference

    func testEffectiveSampleRateUsesFullSpanAverage() async throws {
        let url = try writeJitteryFixture()
        defer { try? FileManager.default.removeItem(at: url) }

        let stream = PlaybackEEGStream(path: url.path, timing: .raw, pacing: .instant)
        _ = try await drain(stream.start())

        // 200 samples nominally at 256 Hz plus one widened gap: the
        // full-span average should stay close to 256 Hz, not be thrown off
        // by reading only the first (unaffected) delta or skewed heavily by
        // the single jittery gap.
        XCTAssertEqual(stream.effectiveSampleRate, 256.0, accuracy: 5.0)
    }
}
