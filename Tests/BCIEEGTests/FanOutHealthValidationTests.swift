import XCTest
@testable import BCICore
@testable import BCIEEG

/// Hardware-free automation of the software half of the Phase B live checklist.
///
/// The manual on-device pass (run against a real Muse) still has to confirm
/// signal plausibility, but the *architecture* — one producer fanning out to
/// two independent consumers, with per-channel health tracking the signal —
/// can be validated deterministically here by driving the real
/// `AsyncMulticastChannel` and the real `EEGChannelHealthProvider` off a
/// synthetic sample pattern.
///
/// To run the same assertions against live or recorded EEG, replace the
/// hand-fed loop below with a `PlaybackEEGStream` (golden recording) or a
/// live `BrainFlowService`, forwarding each sample into the same channel.
final class FanOutHealthValidationTests: XCTestCase {

    /// A raw subscriber and a channel-health provider, both attached to the
    /// same broadcast channel, must simultaneously receive the full stream:
    /// the raw consumer sees every sample, and the health provider leaves
    /// `.unknown` with per-channel status that matches the injected signal
    /// (one deliberately dead channel among three healthy ones).
    func testBothConsumersReceiveStreamAndHealthResolves() async {
        // [TP9, AF7, AF8, TP10] — AF8 held at 0 µV to simulate an electrode
        // lift; the others sit at a healthy 25 µV. RMS is raw sqrt(mean(v^2)),
        // so a constant level maps directly onto the health buckets.
        let channelCount = 4
        let sampleCount = 512
        let healthyLevel: Float = 25
        let deadChannel = 2   // AF8

        let channel = AsyncMulticastChannel<EEGSample>(capacity: 1024, overflow: .dropOldest)

        // Consumer 1: raw sample counter.
        let rawStream = channel.subscribe()
        let rawCounter = Task { () -> Int in
            var n = 0
            for await _ in rawStream { n += 1 }
            return n
        }

        // Consumer 2: the real channel-health provider, reading its own
        // subscription off the same channel.
        let provider = EEGChannelHealthProvider(
            stream: channel.subscribe(),
            channelCount: channelCount,
            channelLabels: ["TP9", "AF7", "AF8", "TP10"],
            sampleRate: 256.0,
            ringSeconds: 4.0
        )

        // Feed the shared channel.
        for i in 0..<sampleCount {
            var channels = [Float](repeating: healthyLevel, count: channelCount)
            channels[deadChannel] = 0
            channel.send(EEGSample(timestamp: TimeInterval(i) / 256.0, channels: channels))
        }

        // Let the provider's drain task ingest before snapshotting.
        try? await Task.sleep(nanoseconds: 80_000_000)
        let states = await provider.currentChannelHealth(windowSeconds: 1.0)

        // Health resolved for every channel (nothing left at .unknown), and
        // the dead channel is isolated from the healthy ones.
        XCTAssertEqual(states.count, channelCount)
        XCTAssertFalse(states.contains { $0.status == .unknown },
                       "all channels should have resolved away from .unknown")
        XCTAssertEqual(states[0].status, .healthy)   // TP9
        XCTAssertEqual(states[1].status, .healthy)   // AF7
        XCTAssertEqual(states[deadChannel].status, .dead)   // AF8
        XCTAssertEqual(states[deadChannel].channel, .af8)
        XCTAssertEqual(states[3].status, .healthy)   // TP10

        // The raw consumer, running concurrently, saw the whole stream —
        // proving the two consumers did not race for a split of it.
        channel.finish()
        let rawCount = await rawCounter.value
        XCTAssertEqual(rawCount, sampleCount)
    }
}
