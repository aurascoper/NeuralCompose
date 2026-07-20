import XCTest
@testable import BCICore
@testable import BCIEEG

/// A realistic AC EEG-like sample value whose windowed RMS ≈ `rms`. Real EEG is
/// ~0-mean AC, so the real-EEG demean (subtract the window mean before RMS, per
/// the amplitude-metrics calibration fix) is a near-no-op and the measured RMS
/// lands on `rms`. A constant DC level, by contrast, demeans to ~0 and is
/// correctly read as a dead channel — which is why these tests feed AC wherever
/// a live/healthy (or saturated) channel is intended. Internal (not private) so
/// `FanOutHealthValidationTests` in the same target can share it.
func acEEGValue(rms: Float, index i: Int, hz: Double = 10, sampleRate: Double = 256) -> Float {
    let amplitude = rms * Float(2.0.squareRoot())   // RMS of A·sin(2πft) = A/√2
    return amplitude * Float(sin(2.0 * .pi * hz * Double(i) / sampleRate))
}

final class EEGChannelHealthProviderTests: XCTestCase {

    // MARK: - Lifecycle

    func testProviderWithNoStreamReturnsUnknownForAllChannels() async {
        let p = EEGChannelHealthProvider(stream: nil)
        let states = await p.currentChannelHealth(windowSeconds: 1.0)
        XCTAssertEqual(states.count, 4)
        for s in states {
            XCTAssertEqual(s.status, .unknown)
            XCTAssertEqual(s.samples, 0)
        }
    }

    func testProviderWithInsufficientSamplesReturnsUnknown() async {
        // 10 samples is well below the 32-sample minimum. Even a
        // clearly healthy signal should report .unknown.
        let (stream, continuation) = AsyncStream<EEGSample>.makeStream()
        let p = EEGChannelHealthProvider(stream: stream)
        for i in 0..<10 {
            continuation.yield(EEGSample(
                timestamp: TimeInterval(i) / 256.0,
                channels: [10, 10, 10, 10]
            ))
        }
        // Give the drain task a moment to consume the buffered
        // samples. (The drain is a detached Task started at init.)
        try? await Task.sleep(nanoseconds: 50_000_000)
        let states = await p.currentChannelHealth(windowSeconds: 1.0)
        continuation.finish()
        for s in states {
            XCTAssertEqual(s.status, .unknown)
        }
    }

    // MARK: - RMS computation

    func testConstantDCSignalDemeansToDeadChannel() async {
        // A pure-DC signal (constant amplitude, zero AC) is the signature of a
        // flat / lifted electrode. After the real-EEG demean (subtract the
        // window mean before RMS), its RMS collapses to ~0, so it is correctly
        // reported .dead — the DC offset no longer masquerades as signal energy,
        // which is exactly the measurement bug the demean fix addressed.
        let dc: Float = 50
        let (stream, continuation) = AsyncStream<EEGSample>.makeStream()
        let p = EEGChannelHealthProvider(stream: stream)
        for i in 0..<256 {
            continuation.yield(EEGSample(
                timestamp: TimeInterval(i) / 256.0,
                channels: [dc, dc, dc, dc]
            ))
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
        let states = await p.currentChannelHealth(windowSeconds: 1.0)
        continuation.finish()

        XCTAssertEqual(states.count, 4)
        for s in states {
            XCTAssertEqual(s.status, .dead)
            XCTAssertEqual(s.samples, 256)
            XCTAssertEqual(s.rms, 0, accuracy: 0.001)
        }
    }

    func testProviderReportsCorrectRMSForSineWave() async {
        // A 10 Hz sine at 256 Hz sample rate, amplitude 100 µV.
        // RMS of A * sin(ωt) is A / sqrt(2) ≈ 70.71 µV.
        let amplitude: Float = 100
        let sampleRate: Double = 256
        let frequency: Double = 10
        let (stream, continuation) = AsyncStream<EEGSample>.makeStream()
        let p = EEGChannelHealthProvider(stream: stream)
        for i in 0..<512 {
            let t = Double(i) / sampleRate
            let v = Float(Double(amplitude) * sin(2.0 * .pi * frequency * t))
            continuation.yield(EEGSample(
                timestamp: t,
                channels: [v, v, v, v]
            ))
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
        let states = await p.currentChannelHealth(windowSeconds: 2.0)
        continuation.finish()

        let expectedRMS = amplitude / Float(sqrt(2.0))
        for s in states {
            // 5% tolerance — the ring wraps at 1024 samples (4 s
            // × 256 Hz) so the 512-sample test fits entirely
            // without wraparound.
            XCTAssertEqual(s.rms, expectedRMS, accuracy: expectedRMS * 0.05)
            XCTAssertEqual(s.status, .healthy)
        }
    }

    func testProviderDetectsSaturatedAndDeadChannelsIndependently() async {
        // Channel layout: TP9 = healthy, AF7 = saturated, AF8 = dead,
        // TP10 = healthy. The provider should classify each
        // channel independently.
        let (stream, continuation) = AsyncStream<EEGSample>.makeStream()
        let p = EEGChannelHealthProvider(stream: stream)
        for i in 0..<256 {
            let t = TimeInterval(i) / 256.0
            let ch: [Float] = [
                acEEGValue(rms: 20, index: i),   // TP9: healthy AC (RMS 20)
                acEEGValue(rms: 500, index: i),  // AF7: saturated AC (RMS 500 > 200)
                0.5,                             // AF8: flat DC → demeans to dead
                acEEGValue(rms: 20, index: i)    // TP10: healthy AC (RMS 20)
            ]
            continuation.yield(EEGSample(timestamp: t, channels: ch))
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
        let states = await p.currentChannelHealth(windowSeconds: 1.0)
        continuation.finish()

        XCTAssertEqual(states[0].channel, .tp9)
        XCTAssertEqual(states[0].status, .healthy)
        XCTAssertEqual(states[1].channel, .af7)
        XCTAssertEqual(states[1].status, .saturated)
        XCTAssertEqual(states[2].channel, .af8)
        XCTAssertEqual(states[2].status, .dead)
        XCTAssertEqual(states[3].channel, .tp10)
        XCTAssertEqual(states[3].status, .healthy)
    }

    // MARK: - Window size

    func testProviderRespectsWindowSeconds() async {
        // The first half of the buffer is a 500 µV saturated
        // signal. The second half is a 10 µV healthy signal. A
        // 1-second window that catches only the second half
        // should report .healthy.
        let (stream, continuation) = AsyncStream<EEGSample>.makeStream()
        let p = EEGChannelHealthProvider(
            stream: stream,
            ringSeconds: 4.0
        )
        // 1024 samples = 4 s at 256 Hz. First 512 saturated AC (RMS 500),
        // last 512 healthy AC (RMS 10). AC, not DC, so the demean leaves the
        // RMS on its target instead of collapsing it to a dead channel.
        for i in 0..<1024 {
            let t = TimeInterval(i) / 256.0
            let v = acEEGValue(rms: i < 512 ? 500 : 10, index: i)
            continuation.yield(EEGSample(timestamp: t, channels: [v, v, v, v]))
        }
        try? await Task.sleep(nanoseconds: 50_000_000)

        // windowSeconds: 1.0 → 256 samples → catches the most
        // recent 256 samples, all of which are the healthy signal.
        let recent = await p.currentChannelHealth(windowSeconds: 1.0)
        for s in recent {
            XCTAssertEqual(s.status, .healthy)
        }

        // windowSeconds: 4.0 → 1024 samples → catches the whole ring (both
        // the saturated and healthy halves). We don't make a strong claim
        // about the combined window's status here; the point is only that the
        // window size changes which samples are measured.
        let all = await p.currentChannelHealth(windowSeconds: 4.0)
        for s in all {
            XCTAssertEqual(s.samples, 1024)
        }
        continuation.finish()
    }

    // MARK: - Staleness

    func testProviderReportsStaleAfterNoIngestForLongerThanTimeout() async {
        // A short staleTimeoutSec (well under the test's own sleep) so
        // the test doesn't need to wait seconds for the real default.
        let (stream, continuation) = AsyncStream<EEGSample>.makeStream()
        let p = EEGChannelHealthProvider(stream: stream, staleTimeoutSec: 0.05)
        for i in 0..<256 {
            let v = acEEGValue(rms: 50, index: i)
            continuation.yield(EEGSample(
                timestamp: TimeInterval(i) / 256.0,
                channels: [v, v, v, v]
            ))
        }
        try? await Task.sleep(nanoseconds: 20_000_000) // let the drain catch up
        // Confirm it's genuinely healthy before staleness kicks in.
        let fresh = await p.currentChannelHealth(windowSeconds: 1.0)
        for s in fresh { XCTAssertEqual(s.status, .healthy) }

        // Let real wall-clock time pass with no further ingest.
        try? await Task.sleep(nanoseconds: 100_000_000)
        let stale = await p.currentChannelHealth(windowSeconds: 1.0)
        continuation.finish()

        XCTAssertEqual(stale.count, 4)
        for s in stale {
            XCTAssertEqual(s.status, .stale, "\(s.channel) should report .stale once no sample has arrived for longer than staleTimeoutSec")
            // rms/samples still carry the frozen diagnostic values —
            // staleness overrides only the status, not the readings. The AC
            // signal's windowed RMS ≈ 50 (loose tolerance: partial-period
            // windowing + demean leave small numeric slack, not exact equality).
            XCTAssertEqual(s.rms, 50, accuracy: 1.0)
        }
    }

    func testProviderWithNoSamplesEverIsNotStale() async {
        // A provider that has never received a sample is .unknown,
        // not .stale — there's nothing stale about "hasn't started yet."
        let p = EEGChannelHealthProvider(stream: nil, staleTimeoutSec: 0.01)
        try? await Task.sleep(nanoseconds: 50_000_000)
        let states = await p.currentChannelHealth(windowSeconds: 1.0)
        for s in states {
            XCTAssertEqual(s.status, .unknown)
        }
    }

    func testProviderStaysFreshWithContinuousIngestPastTheTimeoutWindow() async {
        // Staleness is measured from the *last* ingest, not the
        // first — a stream that keeps producing samples (even slowly)
        // should never go stale, however long it's been running.
        let (stream, continuation) = AsyncStream<EEGSample>.makeStream()
        let p = EEGChannelHealthProvider(stream: stream, staleTimeoutSec: 0.2)
        for round in 0..<3 {
            for i in 0..<64 {
                let idx = round * 64 + i
                let v = acEEGValue(rms: 50, index: idx)
                continuation.yield(EEGSample(
                    timestamp: TimeInterval(idx) / 256.0,
                    channels: [v, v, v, v]
                ))
            }
            try? await Task.sleep(nanoseconds: 50_000_000) // < staleTimeoutSec
        }
        let states = await p.currentChannelHealth(windowSeconds: 1.0)
        continuation.finish()
        for s in states {
            XCTAssertEqual(s.status, .healthy, "continuous ingest should never trip staleness")
        }
    }

    // MARK: - Concurrency

    func testProviderCanBeQueriedFromMultipleTasks() async {
        let (stream, continuation) = AsyncStream<EEGSample>.makeStream()
        let p = EEGChannelHealthProvider(stream: stream)
        for i in 0..<512 {
            let v = acEEGValue(rms: 25, index: i)
            continuation.yield(EEGSample(
                timestamp: TimeInterval(i) / 256.0,
                channels: [v, v, v, v]
            ))
        }
        try? await Task.sleep(nanoseconds: 50_000_000)

        // 8 concurrent queries. None of them should crash; all
        // should return 4 healthy states.
        let results = await withTaskGroup(of: [ChannelHealthState].self) { group in
            for _ in 0..<8 {
                group.addTask {
                    await p.currentChannelHealth(windowSeconds: 1.0)
                }
            }
            var collected: [[ChannelHealthState]] = []
            for await r in group { collected.append(r) }
            return collected
        }
        continuation.finish()

        XCTAssertEqual(results.count, 8)
        for batch in results {
            XCTAssertEqual(batch.count, 4)
            for s in batch {
                XCTAssertEqual(s.status, .healthy)
            }
        }
    }
}
