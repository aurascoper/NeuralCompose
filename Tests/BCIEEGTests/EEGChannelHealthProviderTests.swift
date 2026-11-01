import XCTest
@testable import BCICore
@testable import BCIEEG

/// A realistic AC EEG-like sample value whose windowed RMS is approximately `rms`. Real EEG is
/// ~0-mean AC, so the real-EEG demean (subtract the window mean before RMS, per
/// the amplitude-metrics calibration fix) is a near-no-op and the measured RMS
/// lands on `rms`. A constant DC level, by contrast, demeans to ~0 and is
/// correctly read as a dead channel, which is why these tests feed AC wherever
/// a live/healthy (or saturated) channel is intended. Internal (not private) so
/// `FanOutHealthValidationTests` in the same target can share it.
func acEEGValue(rms: Float, index i: Int, hz: Double = 10, sampleRate: Double = 256) -> Float {
    let amplitude = rms * Float(2.0.squareRoot())   // RMS of A*sin(2*pi*f*t) = A/sqrt(2)
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
        // reported .dead; the DC offset no longer masquerades as signal energy,
        // which is the measurement bug the demean fix addressed.
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
        // A 10 Hz sine at 256 Hz sample rate, amplitude 100 uV.
        // RMS of A * sin(wt) is A / sqrt(2) ~ 70.71 uV.
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
            // 5% tolerance: the ring wraps at 1024 samples (4 s
            // x 256 Hz) so the 512-sample test fits entirely
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
                0.5,                             // AF8: flat DC -> demeans to dead
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

    func testDCOffsetWithHealthyACSignalReportsHealthy() async {
        let (stream, continuation) = AsyncStream<EEGSample>.makeStream()
        let p = EEGChannelHealthProvider(stream: stream)
        let dcBaseline: Float = 820.0
        for i in 0..<256 {
            let t = TimeInterval(i) / 256.0
            let ac = acEEGValue(rms: 20, index: i)
            continuation.yield(EEGSample(
                timestamp: t,
                channels: [dcBaseline + ac, dcBaseline + ac, dcBaseline + ac, dcBaseline + ac]
            ))
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
        let states = await p.currentChannelHealth(windowSeconds: 1.0)
        continuation.finish()

        for s in states {
            XCTAssertEqual(s.status, .healthy)
            XCTAssertEqual(s.rms, 20.0, accuracy: 1.0)
        }
    }

    func testNonFiniteSampleInWindowReportsSaturatedWithoutPoisoningOtherChannels() async {
        let (stream, continuation) = AsyncStream<EEGSample>.makeStream()
        let p = EEGChannelHealthProvider(stream: stream)
        for i in 0..<256 {
            let t = TimeInterval(i) / 256.0
            let ac = acEEGValue(rms: 25, index: i)
            let af7Val: Float = (i == 128) ? .nan : ac
            continuation.yield(EEGSample(
                timestamp: t,
                channels: [ac, af7Val, ac, ac]
            ))
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
        let states = await p.currentChannelHealth(windowSeconds: 1.0)
        continuation.finish()

        XCTAssertEqual(states[0].status, .healthy)
        XCTAssertEqual(states[1].status, .saturated)
        XCTAssertEqual(states[2].status, .healthy)
        XCTAssertEqual(states[3].status, .healthy)
    }

    func testSyntheticAndGenericChannelLabelsMapToDistinctEEGChannels() async {
        let (stream, continuation) = AsyncStream<EEGSample>.makeStream()
        let p = EEGChannelHealthProvider(
            stream: stream,
            channelCount: 4,
            channelLabels: ["syn0", "syn1", "syn2", "syn3"]
        )
        for i in 0..<64 {
            let ac = acEEGValue(rms: 20, index: i)
            continuation.yield(EEGSample(
                timestamp: TimeInterval(i) / 256.0,
                channels: [ac, ac, ac, ac]
            ))
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
        let states = await p.currentChannelHealth(windowSeconds: 0.25)
        continuation.finish()

        XCTAssertEqual(states.map(\.channel), [.tp9, .af7, .af8, .tp10])
    }

    // MARK: - Window size

    func testProviderRespectsWindowSeconds() async {
        // The first half of the buffer is a 500 uV saturated
        // signal. The second half is a 10 uV healthy signal. A
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

        // windowSeconds: 1.0 -> 256 samples -> catches the most
        // recent 256 samples, all of which are the healthy signal.
        let recent = await p.currentChannelHealth(windowSeconds: 1.0)
        for s in recent {
            XCTAssertEqual(s.status, .healthy)
        }

        // windowSeconds: 4.0 -> 1024 samples -> catches the whole ring (both
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
        // Timing margins are deliberately generous so this stays deterministic on
        // a loaded CI runner: staleTimeoutSec (0.3s) must be comfortably LARGER than
        // the setup+drain time before the freshness check (else the channel is
        // already stale when we assert healthy, a real flake at 0.05s), and the
        // later stale-wait must be comfortably larger than the timeout.
        let (stream, continuation) = AsyncStream<EEGSample>.makeStream()
        let p = EEGChannelHealthProvider(stream: stream, staleTimeoutSec: 0.3)
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

        // Let real wall-clock time pass with no further ingest, well past the 0.3s
        // timeout so staleness is unambiguous regardless of runner scheduling jitter.
        try? await Task.sleep(nanoseconds: 500_000_000)
        let stale = await p.currentChannelHealth(windowSeconds: 1.0)
        continuation.finish()

        XCTAssertEqual(stale.count, 4)
        for s in stale {
            XCTAssertEqual(s.status, .stale, "\(s.channel) should report .stale once no sample has arrived for longer than staleTimeoutSec")
            // rms/samples still carry the frozen diagnostic values;
            // staleness overrides only the status, not the readings. The AC
            // signal's windowed RMS ~ 50 (loose tolerance: partial-period
            // windowing + demean leave small numeric slack, not exact equality).
            XCTAssertEqual(s.rms, 50, accuracy: 1.0)
        }
    }

    func testProviderWithNoSamplesEverIsNotStale() async {
        // A provider that has never received a sample is .unknown,
        // not .stale; there is nothing stale about "hasn't started yet."
        let p = EEGChannelHealthProvider(stream: nil, staleTimeoutSec: 0.01)
        try? await Task.sleep(nanoseconds: 50_000_000)
        let states = await p.currentChannelHealth(windowSeconds: 1.0)
        for s in states {
            XCTAssertEqual(s.status, .unknown)
        }
    }

    func testProviderStaysFreshWithContinuousIngestPastTheTimeoutWindow() async {
        // Staleness is measured from the *last* ingest, not the
        // first; a stream that keeps producing samples (even slowly)
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

    // MARK: - EEGScalpPlotterView DC Baseline & Partial-Buffer Rendering

    @MainActor
    func testScalpPlotterDemeansFullAndPartialBuffersWithMuseDCOffset() {
        let plotter = EEGScalpPlotterView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
        plotter.layout()
        let perChannelHeight: CGFloat = 100.0
        let expectedMidY = perChannelHeight / 2.0 // 50.0 pt for channel 0

        // 1. Partial startup buffer: 256 samples (1.0s out of 5.0s = 1280 slots)
        //    with +820 uV Muse DC offset and +/-20 uV AC wave.
        for i in 0..<256 {
            let ac: Float = (i % 2 == 0) ? 20.0 : -20.0
            let v: Float = 820.0 + ac
            plotter.ingest(EEGSample(
                timestamp: TimeInterval(i) / 256.0,
                channels: [v, v, v, v]
            ))
        }
        plotter.testableTriggerRedraw()
        guard let partialBox = plotter.testableLayerPathBoundingBox(channelIndex: 0) else {
            XCTFail("Expected non-nil path bounding box for channel 0")
            return
        }
        // +/-20 uV at yScale=2.0 spans [10, 90] around midY=50 (height ~80 pt).
        // Without partial-window DC baseline bounding, 1024 leading zeros skewed
        // dcBaseline to 164 uV and threw the trace off-screen (height > 1600 pt).
        XCTAssertEqual(partialBox.midY, expectedMidY, accuracy: 2.0)
        XCTAssertEqual(partialBox.height, 80.0, accuracy: 4.0)

        // 2. Full buffer (1280+ samples) with +820 uV DC offset and a planted NaN sample.
        for i in 256..<1400 {
            let ac: Float = (i % 2 == 0) ? 20.0 : -20.0
            let v: Float = (i == 900) ? .nan : (820.0 + ac)
            plotter.ingest(EEGSample(
                timestamp: TimeInterval(i) / 256.0,
                channels: [v, v, v, v]
            ))
        }
        plotter.testableTriggerRedraw()
        guard let fullBox = plotter.testableLayerPathBoundingBox(channelIndex: 0) else {
            XCTFail("Expected non-nil path bounding box for channel 0 after full buffer")
            return
        }
        XCTAssertTrue(fullBox.origin.x.isFinite && fullBox.origin.y.isFinite)
        XCTAssertEqual(fullBox.midY, expectedMidY, accuracy: 2.0)
        XCTAssertEqual(fullBox.height, 80.0, accuracy: 4.0)
    }

    // MARK: - Contralateral Bad-Channel Partner Substitution

    func testContralateralPartnerMappingMatchesPythonChannelPairs() {
        XCTAssertEqual(EEGChannel.tp9.contralateralPartner, .tp10)
        XCTAssertEqual(EEGChannel.tp10.contralateralPartner, .tp9)
        XCTAssertEqual(EEGChannel.af7.contralateralPartner, .af8)
        XCTAssertEqual(EEGChannel.af8.contralateralPartner, .af7)
        XCTAssertEqual(
            EEGChannelHealthProvider.channelPairs,
            ["TP9": "TP10", "TP10": "TP9", "AF7": "AF8", "AF8": "AF7"]
        )
    }

    func testSubstituteBadChannelsReplacesDeadAndSaturatedWithDemeanedHealthyPartner() {
        let n = 512
        let dc: Float = 820.0
        let tp9Dead = Array(repeating: dc, count: n) // 0 uV AC -> dead
        let af7Saturated: [Float] = (0..<n).map { i in
            dc + acEEGValue(rms: 450, index: i)      // 450 uV RMS -> saturated
        }
        let af8Healthy: [Float] = (0..<n).map { i in
            dc + acEEGValue(rms: 25, index: i, hz: 10)
        }
        let tp10Healthy: [Float] = (0..<n).map { i in
            dc + acEEGValue(rms: 30, index: i, hz: 12)
        }

        let raw = EEGWindow(
            samples: [tp9Dead, af7Saturated, af8Healthy, tp10Healthy],
            sampleRate: 256,
            endTimestamp: 2.0,
            sequence: 7
        )
        let cleaned = EEGChannelHealthProvider.substituteBadChannels(in: raw)

        // TP9 (ch 0) was dead -> replaced with demeaned TP10 (ch 3)
        // AF7 (ch 1) was saturated -> replaced with demeaned AF8 (ch 2)
        for s in 0..<n {
            let expectedTP9 = acEEGValue(rms: 30, index: s, hz: 12)
            let expectedAF7 = acEEGValue(rms: 25, index: s, hz: 10)
            XCTAssertEqual(cleaned.samples[0][s], expectedTP9, accuracy: 0.05)
            XCTAssertEqual(cleaned.samples[1][s], expectedAF7, accuracy: 0.05)
            // Healthy channels keep their original samples.
            XCTAssertEqual(cleaned.samples[2][s], af8Healthy[s], accuracy: 1e-4)
            XCTAssertEqual(cleaned.samples[3][s], tp10Healthy[s], accuracy: 1e-4)
        }

        // FeatureExtractor(substituteBadChannels: true) and JEPASpectralState also
        // substitute bad channels before extracting band powers.
        let extracted = FeatureExtractor.features(for: raw, substituteBadChannels: true)
        XCTAssertEqual(extracted.rmsByChannel.count, 4)
        XCTAssertEqual(extracted.rmsByChannel[0], 30.0, accuracy: 0.5)
        XCTAssertEqual(extracted.rmsByChannel[1], 25.0, accuracy: 0.5)
        XCTAssertTrue(extracted.alphaEnergy.isFinite && extracted.alphaEnergy > 0)

        let jepaState = JEPASpectralState(window: raw, timestamp: 2.0)
        XCTAssertNotNil(jepaState)
        if let jepaState {
            XCTAssertTrue(jepaState.alphaPower.isFinite)
            XCTAssertTrue(jepaState.betaPower.isFinite)
            XCTAssertTrue(jepaState.thetaPower.isFinite)
            for v in jepaState.channelPowers {
                XCTAssertTrue(v.isFinite)
                XCTAssertGreaterThan(v, 0)
            }
        }
    }

    func testSubstituteBadChannelsLeavesWindowUnchangedWhenBothPartnersAreBad() {
        let n = 512
        let dc: Float = 820.0
        let dead = Array(repeating: dc, count: n)
        let saturated: [Float] = (0..<n).map { i in dc + acEEGValue(rms: 450, index: i) }
        let raw = EEGWindow(
            samples: [dead, saturated, saturated, dead],
            sampleRate: 256,
            endTimestamp: 2.0,
            sequence: 8
        )
        let out = EEGChannelHealthProvider.substituteBadChannels(in: raw)
        XCTAssertEqual(out.samples, raw.samples)
    }

    func testFeatureExtractorAndJEPASpectralStateSurviveUnsubstitutedNaNWhenBothPartnersAreBad() {
        let n = 512
        let dc: Float = 820.0
        let tp9Healthy: [Float] = (0..<n).map { i in dc + acEEGValue(rms: 25, index: i, hz: 10) }
        var af7WithNaN: [Float] = (0..<n).map { i in dc + acEEGValue(rms: 30, index: i, hz: 10) }
        af7WithNaN[200] = .nan
        let af8Dead = Array(repeating: dc, count: n) // partner is also bad (.dead), so AF7 cannot be substituted
        let tp10Healthy: [Float] = (0..<n).map { i in dc + acEEGValue(rms: 25, index: i, hz: 10) }

        let raw = EEGWindow(
            samples: [tp9Healthy, af7WithNaN, af8Dead, tp10Healthy],
            sampleRate: 256,
            endTimestamp: 2.0,
            sequence: 9
        )
        let feats = FeatureExtractor.features(for: raw, substituteBadChannels: true)
        for rms in feats.rmsByChannel {
            XCTAssertTrue(rms.isFinite, "Expected finite channel RMS even with unsubstituted NaN, got \(rms)")
        }
        XCTAssertGreaterThan(feats.rmsByChannel[1], 20.0, "Single NaN sample must not zero out or poison the remaining 511 finite samples")
        XCTAssertTrue(feats.deltaEnergy.isFinite)
        XCTAssertTrue(feats.thetaEnergy.isFinite)
        XCTAssertTrue(feats.alphaEnergy.isFinite && feats.alphaEnergy > 0)
        XCTAssertTrue(feats.betaEnergy.isFinite)
        XCTAssertTrue(feats.emgEnergy.isFinite)

        let jepaState = JEPASpectralState(window: raw, timestamp: 2.0)
        XCTAssertNotNil(jepaState, "JEPASpectralState must remain non-nil when one pair of channels cannot be substituted")
    }

    // MARK: - BrainFlow Muse S <-> Athena Fallback & MindMonitorOSCStream Teardown

    func testBrainFlowServiceMuseSFallbackProfileAndParamsJSON() {
        XCTAssertEqual(BrainFlowService.fallbackMuseSProfile(for: .museSNativeBLE), .museSAthena)
        XCTAssertEqual(BrainFlowService.fallbackMuseSProfile(for: .museSAthena), .museSNativeBLE)
        XCTAssertEqual(BrainFlowService.fallbackMuseSProfile(for: .museTwoNativeBLE), .museSAthena)
        XCTAssertNil(BrainFlowService.fallbackMuseSProfile(for: .synthetic))
        XCTAssertNil(BrainFlowService.fallbackMuseSProfile(for: .oscRemote))

        let svc = BrainFlowService(profile: .museSNativeBLE)
        XCTAssertEqual(svc.preferredProfile, .museSNativeBLE)
        let primaryJSON = svc.makeParamsJSON(for: .museSNativeBLE, environment: [:])
        XCTAssertTrue(primaryJSON.contains("\"other_info\":\"\""))
        XCTAssertTrue(primaryJSON.contains("\"timeout\":20"))

        let fallbackAthenaJSON = svc.makeParamsJSON(for: .museSAthena, environment: [:])
        XCTAssertTrue(fallbackAthenaJSON.contains("\"other_info\":\"preset=p1041;low_latency=true\""))

        // When NEURALCOMPOSE_BRAINFLOW_OTHER_INFO contains Athena-only tokens, falling
        // back to .museSNativeBLE (39) must strip low_latency and p10xx/p41xx presets so
        // BrainFlow's legacy MuseOptions parser does not fail with INVALID_ARGUMENTS_ERROR.
        let sanitizedLegacyJSON = svc.makeParamsJSON(
            for: .museSNativeBLE,
            environment: ["NEURALCOMPOSE_BRAINFLOW_OTHER_INFO": "preset=p1041;low_latency=true;p21"]
        )
        XCTAssertTrue(sanitizedLegacyJSON.contains("\"other_info\":\"p21\""), "Got: \(sanitizedLegacyJSON)")

        // Zero-sample stall on board 39 promotes sibling board 67 (.museSAthena) for the next retry.
        XCTAssertEqual(svc.recordZeroSampleStall(for: .museSNativeBLE), .museSAthena)
        XCTAssertEqual(svc.preferredProfile, .museSAthena)
        XCTAssertEqual(svc.recordZeroSampleStall(for: .museSAthena), .museSNativeBLE)
        XCTAssertEqual(svc.preferredProfile, .museSNativeBLE)
    }

    func testMindMonitorOSCStreamStopCancelsWatchdogAndActiveConnections() async throws {
        let port: UInt16 = 59421
        let stream = MindMonitorOSCStream(port: port, staleTimeoutSec: 5.0)
        let eegStream = try await stream.start()
        XCTAssertTrue(stream.hasActiveWatchdog)

        // Wait for NWListener to bind and send a UDP datagram to loopback:port
        // so NWListener's newConnectionHandler creates and tracks an active NWConnection.
        let fd = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { if fd >= 0 { Darwin.close(fd) } }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let packet: [UInt8] = [0x2f, 0x6d, 0x75, 0x73, 0x65, 0x00, 0x00, 0x00, 0x2c, 0x00, 0x00, 0x00]

        let deadline = Date().addingTimeInterval(2.0)
        while stream.activeConnectionCount == 0 && Date() < deadline {
            if fd >= 0 {
                packet.withUnsafeBytes { rawBuf in
                    withUnsafePointer(to: &addr) { addrPtr in
                        addrPtr.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPtr in
                            _ = Darwin.sendto(fd, rawBuf.baseAddress, rawBuf.count, 0, saPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
                        }
                    }
                }
            }
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTAssertGreaterThanOrEqual(
            stream.activeConnectionCount,
            1,
            "Expected UDP datagram to create at least one tracked NWConnection before stop()"
        )

        await stream.stop()
        XCTAssertFalse(stream.hasActiveWatchdog)
        XCTAssertEqual(stream.activeConnectionCount, 0)
        withExtendedLifetime(eegStream) {}
    }
}
